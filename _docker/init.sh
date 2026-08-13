#!/bin/sh
# minio — инициализация хранилища: бакеты и сервисный аккаунт CRM.
#
# Запускается сервисом minio-init (образ minio/mc) после того, как healthcheck сервера
# ответил «готов». Скрипт лежит в репозитории, а не строкой в entrypoint внутри YAML:
# логика перестала быть однострочной, а многострочный shell в свёрнутом блоке compose —
# это экранирование в двух слоях сразу и правки вслепую.
#
# ⚠️ Скрипт ИДЕМПОТЕНТЕН и рассчитан на то, что его гоняют при каждой выкатке. Ничего не
# удаляет и не пересоздаёт: бакеты — с --ignore-existing, политика перезаписывается своим
# же содержимым, пользователю выравнивается секретный ключ из окружения. Именно поэтому
# аккаунт CRM переживает пересоздание стека (`docker compose down && up`) — он не заведён
# руками в консоли, а описан здесь.
#
# ЗАЧЕМ СЕРВИСНЫЙ АККАУНТ (HAP-509). CRM ходит в хранилище ROOT-кредами (`hd-minio-admin`):
# один и тот же секрет лежал и в minio/.env, и в crm/.env, то есть тот, кто катит CRM,
# владел хранилищем целиком — включая записи разговоров и файлы WhatsApp. Отдельный
# пользователь с политикой ровно на нужные бакеты возвращает границу: за пределы своих
# бакетов он выйти не может и создать новый — тоже.
#
# Аккаунт ДОБАВЛЯЕТСЯ рядом. Root-креды не отзываются и не ротируются: CRM продолжает
# работать на них, пока владелец сервиса не переключит своё окружение (стадия 2, HAP-509).

set -eu

: "${MINIO_ROOT_USER:?init: не задан MINIO_ROOT_USER}"
: "${MINIO_ROOT_PASSWORD:?init: не задан MINIO_ROOT_PASSWORD}"

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
MINIO_BUCKETS="${MINIO_BUCKETS:-registry,record,whatsapp}"
MINIO_CRM_ACCESS_KEY="${MINIO_CRM_ACCESS_KEY:-}"
MINIO_CRM_SECRET_KEY="${MINIO_CRM_SECRET_KEY:-}"
MINIO_CRM_BUCKETS="${MINIO_CRM_BUCKETS:-$MINIO_BUCKETS}"
MINIO_CRM_POLICY="${MINIO_CRM_POLICY:-crm-app}"

# Алиас в HOME контейнера; наружу конфиг mc не переживает — контейнер одноразовый.
mc alias set local "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

# --- Бакеты ---------------------------------------------------------------------------
# Сам MinIO их не создаёт: MINIO_DEFAULT_BUCKETS — переменная образа bitnami, официальный
# minio/minio её игнорирует (проверено 10.08.2026). Отсюда и весь этот сервис.
for b in $(echo "$MINIO_BUCKETS" | tr ',' ' '); do
    mc mb --ignore-existing "local/$b" >/dev/null
    echo "bucket ready: $b"
done

# --- Сервисный аккаунт CRM ------------------------------------------------------------
# Ключи приезжают из окружения (.env на хосте, куда их кладёт выкатка из Credentials Store
# папки `crm` — jenkins-infra/DEPLOY.md §10). В гите их нет и быть не может.
#
# Пустое значение — не ошибка: на хосте, где ключи ещё не разложены, стек обязан
# подняться, а бакеты — создаться. Иначе первая же выкатка на новую машину падала бы на
# том, чего там пока нет.
if [ -z "$MINIO_CRM_ACCESS_KEY" ] || [ -z "$MINIO_CRM_SECRET_KEY" ]; then
    echo "crm service account: пропуск — MINIO_CRM_ACCESS_KEY/MINIO_CRM_SECRET_KEY не заданы (см. .env.example)"
    exit 0
fi

# Ограничения MinIO: логин ≥ 3 символов, пароль ≥ 8. Проверяем здесь, потому что
# `mc admin user add` на коротком значении отвечает невнятной ошибкой валидации.
if [ "${#MINIO_CRM_ACCESS_KEY}" -lt 3 ] || [ "${#MINIO_CRM_SECRET_KEY}" -lt 8 ]; then
    echo "crm service account: ОШИБКА — access key ≥ 3 символов, secret key ≥ 8" >&2
    exit 1
fi

# Собираем ресурсы политики из списка бакетов. Два уровня, потому что в S3 это разные
# ARN: право читать список объектов даётся на бакет, право трогать объект — на bucket/*.
crm_bucket_arns=''
crm_object_arns=''
for b in $(echo "$MINIO_CRM_BUCKETS" | tr ',' ' '); do
    # Бакет CRM обязан существовать до выдачи прав: политика на несуществующий бакет
    # применяется молча, а приложение потом падает на NoSuchBucket уже в рантайме.
    mc mb --ignore-existing "local/$b" >/dev/null
    crm_bucket_arns="${crm_bucket_arns:+$crm_bucket_arns, }\"arn:aws:s3:::$b\""
    crm_object_arns="${crm_object_arns:+$crm_object_arns, }\"arn:aws:s3:::$b/*\""
done

if [ -z "$crm_bucket_arns" ]; then
    echo "crm service account: ОШИБКА — MINIO_CRM_BUCKETS пуст, политика без ресурсов дала бы аккаунт без доступа" >&2
    exit 1
fi

# Политика перечисляет действия явно, а не s3:*. Встроенная `readwrite` в MinIO — это
# `s3:*` на `arn:aws:s3:::*`, то есть ровно то, от чего мы уходим. Здесь нет ни создания
# бакетов, ни их удаления, ни admin-действий: аккаунт живёт внутри выданных бакетов.
#
# Действия по multipart нужны Flysystem: загрузка крупного файла идёт multipart, и без
# них она обрывается на середине. Границы они не расширяют — ресурсы те же.
#
# ⚠️ s3:GetObjectAcl / s3:PutObjectAcl сюда НЕ вписывать: MinIO их не знает и отвечает
# `unsupported action` прямо на создании политики (проверено 13.08.2026 на
# RELEASE.2025-09-07). Per-object ACL он не реализует вовсе — Flysystem-visibility
# на этом хранилище и так ни на что не влияет.
policy_file=/tmp/crm-policy.json
cat > "$policy_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CrmBucketLevel",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": [$crm_bucket_arns]
    },
    {
      "Sid": "CrmObjectLevel",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [$crm_object_arns]
    }
  ]
}
EOF

mc admin policy create local "$MINIO_CRM_POLICY" "$policy_file" >/dev/null
echo "policy ready: $MINIO_CRM_POLICY -> $MINIO_CRM_BUCKETS"

# `user add` на существующем пользователе выравнивает секретный ключ — это и есть наша
# ротация: поменяли значение в Credentials Store, выкатка донесла его сюда.
mc admin user add local "$MINIO_CRM_ACCESS_KEY" "$MINIO_CRM_SECRET_KEY" >/dev/null
mc admin user enable local "$MINIO_CRM_ACCESS_KEY" >/dev/null

# `policy attach` на уже привязанной политике возвращает ненулевой код с сообщением
# «policy change is already in effect». Это норма при повторном прогоне, а не сбой,
# поэтому сверяемся с фактическим состоянием, а не глушим ошибку через `|| true`.
if ! mc admin policy attach local "$MINIO_CRM_POLICY" --user "$MINIO_CRM_ACCESS_KEY" >/dev/null 2>&1; then
    if ! mc admin user info local "$MINIO_CRM_ACCESS_KEY" | grep -q "$MINIO_CRM_POLICY"; then
        echo "crm service account: ОШИБКА — политика $MINIO_CRM_POLICY не привязана к $MINIO_CRM_ACCESS_KEY" >&2
        exit 1
    fi
fi

echo "crm service account ready: $MINIO_CRM_ACCESS_KEY (политика $MINIO_CRM_POLICY)"
