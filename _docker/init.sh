#!/bin/sh
# minio — инициализация хранилища: бакеты и сервисные аккаунты приложений.
#
# Запускается сервисом minio-init (образ minio/mc) после того, как healthcheck сервера
# ответил «готов». Скрипт лежит в репозитории, а не строкой в entrypoint внутри YAML:
# логика перестала быть однострочной, а многострочный shell в свёрнутом блоке compose —
# это экранирование в двух слоях сразу и правки вслепую.
#
# ⚠️ Скрипт ИДЕМПОТЕНТЕН и рассчитан на то, что его гоняют при каждой выкатке. Ничего не
# удаляет и не пересоздаёт: бакеты — с --ignore-existing, политика перезаписывается своим
# же содержимым, пользователю выравнивается секретный ключ из окружения. Именно поэтому
# аккаунты переживают пересоздание стека (`docker compose down && up`) — они не заведены
# руками в консоли, а описаны здесь.
#
# ЗАЧЕМ СЕРВИСНЫЕ АККАУНТЫ. Приложения ходили в хранилище ROOT-кредами (`hd-minio-admin`):
# один и тот же секрет лежал и в minio/.env, и в .env потребителя, то есть тот, кто катит
# приложение, владел хранилищем целиком — включая записи разговоров и файлы WhatsApp.
# Отдельный пользователь с политикой ровно на нужные бакеты возвращает границу: за пределы
# своих бакетов он выйти не может и создать новый — тоже.
#
#   * `crm-app`      — CRM (HAP-509): registry / record / whatsapp / documents /
#                      chat-attachments, чтение и запись. Все диски CRM (`s3`, `s3records`,
#                      `s3whatsapp`, `s3documents`, `s3chat`) ходят одной парой ключей,
#                      поэтому учётка одна на сервис, а не на бакет.
#   * `telephony-ari` — телефония (HAP-516): бакет записей разговоров, БЕЗ удаления.
#
# Аккаунты ДОБАВЛЯЮТСЯ рядом. Root-креды здесь не отзываются и не ротируются — это
# отдельный шаг (HAP-517), и он возможен только когда на root не осталось потребителей.

set -eu

: "${MINIO_ROOT_USER:?init: не задан MINIO_ROOT_USER}"
: "${MINIO_ROOT_PASSWORD:?init: не задан MINIO_ROOT_PASSWORD}"

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
MINIO_BUCKETS="${MINIO_BUCKETS:-registry,record,whatsapp,documents,chat-attachments}"

MINIO_CRM_ACCESS_KEY="${MINIO_CRM_ACCESS_KEY:-}"
MINIO_CRM_SECRET_KEY="${MINIO_CRM_SECRET_KEY:-}"
MINIO_CRM_BUCKETS="${MINIO_CRM_BUCKETS:-$MINIO_BUCKETS}"
MINIO_CRM_POLICY="${MINIO_CRM_POLICY:-crm-app}"

MINIO_TELEPHONY_ACCESS_KEY="${MINIO_TELEPHONY_ACCESS_KEY:-}"
MINIO_TELEPHONY_SECRET_KEY="${MINIO_TELEPHONY_SECRET_KEY:-}"
MINIO_TELEPHONY_BUCKETS="${MINIO_TELEPHONY_BUCKETS:-record}"
MINIO_TELEPHONY_POLICY="${MINIO_TELEPHONY_POLICY:-telephony-ari}"

MINIO_FILES_ACCESS_KEY="${MINIO_FILES_ACCESS_KEY:-}"
MINIO_FILES_SECRET_KEY="${MINIO_FILES_SECRET_KEY:-}"
MINIO_FILES_BUCKETS="${MINIO_FILES_BUCKETS:-documents}"
MINIO_FILES_POLICY="${MINIO_FILES_POLICY:-file-service}"
# Срок хранения объектов в бакете file_service (HAP-620). Пусто = не удаляется ничего.
MINIO_FILES_EXPIRE_DAYS="${MINIO_FILES_EXPIRE_DAYS:-}"

# Алиас в HOME контейнера; наружу конфиг mc не переживает — контейнер одноразовый.
mc alias set local "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

# --- Бакеты ---------------------------------------------------------------------------
# Сам MinIO их не создаёт: MINIO_DEFAULT_BUCKETS — переменная образа bitnami, официальный
# minio/minio её игнорирует (проверено 10.08.2026). Отсюда и весь этот сервис.
for b in $(echo "$MINIO_BUCKETS" | tr ',' ' '); do
    mc mb --ignore-existing "local/$b" >/dev/null
    echo "bucket ready: $b"
done

# --- Заведение одного сервисного аккаунта ----------------------------------------------
# Аргументы: <ярлык> <access key> <secret key> <бакеты через запятую> <имя политики>
#            <Sid-префикс> <объектные действия через запятую>
#
# Ключи приезжают из окружения (.env на хосте, куда их кладёт выкатка из Credentials Store
# папки проекта — jenkins-infra/DEPLOY.md §10). В гите их нет и быть не может.
#
# Функция ВОЗВРАЩАЕТ 0 и на пропуске: пустые ключи — не ошибка. На хосте, где ключи ещё не
# разложены, стек обязан подняться, а бакеты — создаться, иначе первая же выкатка на новую
# машину падала бы на том, чего там пока нет. И пропуск одного аккаунта не должен мешать
# завести второй — раньше здесь стоял `exit 0`, и незаполненные ключи CRM тихо унесли бы
# с собой заведение телефонии.
provision_account() {
    label="$1"
    access_key="$2"
    secret_key="$3"
    buckets="$4"
    policy_name="$5"
    sid_prefix="$6"
    object_actions="$7"

    if [ -z "$access_key" ] || [ -z "$secret_key" ]; then
        echo "$label service account: пропуск — ключи не заданы (см. .env.example)"
        return 0
    fi

    # Ограничения MinIO: логин ≥ 3 символов, пароль ≥ 8. Проверяем здесь, потому что
    # `mc admin user add` на коротком значении отвечает невнятной ошибкой валидации.
    if [ "${#access_key}" -lt 3 ] || [ "${#secret_key}" -lt 8 ]; then
        echo "$label service account: ОШИБКА — access key ≥ 3 символов, secret key ≥ 8" >&2
        return 1
    fi

    # Собираем ресурсы политики из списка бакетов. Два уровня, потому что в S3 это разные
    # ARN: право читать список объектов даётся на бакет, право трогать объект — на bucket/*.
    bucket_arns=''
    object_arns=''
    for b in $(echo "$buckets" | tr ',' ' '); do
        # Бакет обязан существовать до выдачи прав: политика на несуществующий бакет
        # применяется молча, а приложение потом падает на NoSuchBucket уже в рантайме.
        mc mb --ignore-existing "local/$b" >/dev/null
        bucket_arns="${bucket_arns:+$bucket_arns, }\"arn:aws:s3:::$b\""
        object_arns="${object_arns:+$object_arns, }\"arn:aws:s3:::$b/*\""
    done

    if [ -z "$bucket_arns" ]; then
        echo "$label service account: ОШИБКА — список бакетов пуст, политика без ресурсов дала бы аккаунт без доступа" >&2
        return 1
    fi

    # Объектные действия приходят списком через запятую — разворачиваем в JSON-массив.
    object_action_json=''
    for a in $(echo "$object_actions" | tr ',' ' '); do
        object_action_json="${object_action_json:+$object_action_json,
        }\"$a\""
    done

    # Политика перечисляет действия явно, а не s3:*. Встроенная `readwrite` в MinIO — это
    # `s3:*` на `arn:aws:s3:::*`, то есть ровно то, от чего мы уходим. Здесь нет ни создания
    # бакетов, ни их удаления, ни admin-действий: аккаунт живёт внутри выданных бакетов.
    #
    # Действия по multipart нужны загрузке крупного файла: она идёт multipart, и без них
    # обрывается на середине. Границы они не расширяют — ресурсы те же.
    #
    # ⚠️ s3:GetObjectAcl / s3:PutObjectAcl сюда НЕ вписывать: MinIO их не знает и отвечает
    # `unsupported action` прямо на создании политики (проверено 13.08.2026 на
    # RELEASE.2025-09-07). Per-object ACL он не реализует вовсе.
    policy_file="/tmp/$policy_name-policy.json"
    cat > "$policy_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "${sid_prefix}BucketLevel",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": [$bucket_arns]
    },
    {
      "Sid": "${sid_prefix}ObjectLevel",
      "Effect": "Allow",
      "Action": [
        $object_action_json
      ],
      "Resource": [$object_arns]
    }
  ]
}
EOF

    mc admin policy create local "$policy_name" "$policy_file" >/dev/null
    echo "policy ready: $policy_name -> $buckets"

    # `user add` на существующем пользователе выравнивает секретный ключ — это и есть наша
    # ротация: поменяли значение в Credentials Store, выкатка донесла его сюда.
    mc admin user add local "$access_key" "$secret_key" >/dev/null
    mc admin user enable local "$access_key" >/dev/null

    # `policy attach` на уже привязанной политике возвращает ненулевой код с сообщением
    # «policy change is already in effect». Это норма при повторном прогоне, а не сбой,
    # поэтому сверяемся с фактическим состоянием, а не глушим ошибку через `|| true`.
    if ! mc admin policy attach local "$policy_name" --user "$access_key" >/dev/null 2>&1; then
        if ! mc admin user info local "$access_key" | grep -q "$policy_name"; then
            echo "$label service account: ОШИБКА — политика $policy_name не привязана к $access_key" >&2
            return 1
        fi
    fi

    echo "$label service account ready: $access_key (политика $policy_name)"
}

# --- Правила жизненного цикла бакета ---------------------------------------------------
# Аргументы: <бакет> <дней до удаления объекта>
# Пустой срок = правило не ставится и существующая конфигурация не трогается.
#
# Идемпотентность — через `mc ilm rule import`: он ЗАМЕНЯЕТ конфигурацию бакета целиком
# тем, что подали на вход. `mc ilm rule add` при каждом прогоне добавлял бы ещё одно
# правило с новым сгенерированным ID, и после десятка выкаток в бакете лежала бы стопка
# дублей — а скрипт гоняется на каждой выкатке.
#
# ⚠️ Обратная сторона замены: правило, заведённое руками через консоль, следующая выкатка
# сотрёт. Правила живут здесь, в коде, — как и сами аккаунты. Снять правило = очистить
# срок в .env И один раз выполнить `mc ilm rule rm --all --force local/<бакет>`: пустой
# список сюда сознательно не подаётся, чтобы опечатка в переменной не обнулила молча
# жизненный цикл работающего бакета.
#
# ⚠️ Правила на брошенные multipart-загрузки здесь НЕТ намеренно, хотя в S3 такое действие
# есть (AbortIncompleteMultipartUpload). MinIO его в lifecycle не принимает — отвечает
# «XML ... did not validate against our published schema», и флага под него нет даже в
# `mc ilm rule add` (проверено 19.08.2026 на RELEASE.2025-09-07 + mc RELEASE.2025-04-16).
# Убирает их сам сервер: `mc admin config get <alias> api` → stale_uploads_expiry=24h,
# stale_uploads_cleanup_interval=6h. То есть проблема решена, просто не здесь.
apply_lifecycle() {
    bucket="$1"
    expire_days="$2"

    # Бакет может быть не заведён: на хосте список бакетов задан в .env явным значением и
    # не обязан совпадать с дефолтом из репозитория (HAP-539). Правило на несуществующий
    # бакет — ошибка, поэтому создаём здесь же.
    mc mb --ignore-existing "local/$bucket" >/dev/null

    if [ -z "$expire_days" ]; then
        echo "lifecycle: $bucket — срок хранения не задан, конфигурация не менялась"
        return 0
    fi

    ilm_file="/tmp/$bucket-ilm.json"
    printf '{"Rules":[{"ID":"expire-objects","Status":"Enabled","Expiration":{"Days":%s}}]}' "$expire_days" > "$ilm_file"
    mc ilm rule import "local/$bucket" < "$ilm_file" >/dev/null
    echo "lifecycle ready: $bucket (expire: $expire_days дн.)"
}

# --- Сервисный аккаунт CRM (HAP-509) ---------------------------------------------------
# Чтение и запись в свои бакеты, включая удаление: CRM управляет жизненным циклом
# загруженных документов и файлов WhatsApp.
#
# HAP-535: сюда же добавлен `chat-attachments` — вложения и голосовые внутреннего чата
# операторов. Тот же набор действий подходит без оговорок: удаление сообщения с файлом
# должно уносить и объект, иначе бакет копит осиротевшие вложения, на которые уже никто
# не сошлётся. Отдельная учётка не заводится: потребитель один и тот же — CRM.
provision_account \
    'crm' \
    "$MINIO_CRM_ACCESS_KEY" \
    "$MINIO_CRM_SECRET_KEY" \
    "$MINIO_CRM_BUCKETS" \
    "$MINIO_CRM_POLICY" \
    'Crm' \
    's3:GetObject,s3:PutObject,s3:DeleteObject,s3:AbortMultipartUpload,s3:ListMultipartUploadParts'

# --- Сервисный аккаунт телефонии (HAP-516) ---------------------------------------------
# telephony-ari складывает в хранилище записи разговоров. До HAP-516 он ходил туда
# ROOT-кредами: те же `hd-minio-admin` + MINIO_ROOT_PASSWORD лежали у него в .env.secrets
# (сверено по sha256 13.08.2026). Пока это так, ротация root ломала бы запись разговоров,
# поэтому HAP-517 и ждал этой задачи.
#
# Права ýже, чем у CRM: набор ровно под то, что делает клиент
# (workers/file_service/minio_client.py):
#
#   * bucket_exists → HeadBucket        → s3:ListBucket на бакете;
#   * fput_object   → PutObject         → s3:PutObject + multipart на объектах;
#   * запись читает STT-воркер          → s3:GetObject (ключи уезжают ему в задании).
#
# 🔴 s3:DeleteObject НЕ выдаётся сознательно. Телефония объекты только кладёт — удаления в
# коде нет вовсе. Запись разговора это ПДн высокой чувствительности и единственный
# экземпляр: право её удалить не нужно никому, кто её создаёт.
#
# 🔴 Создания бакетов тоже нет, и это меняет поведение. Клиент при первой загрузке делает
# `make_bucket`, если бакета не оказалось, — под root это МОЛЧА создавало бакет с опечаткой
# в имени вместо ошибки. Под узкой учёткой промах по имени станет внятным AccessDenied.
# Это ровно то, чего мы хотим: см. расхождение `record` / `records` в README.
provision_account \
    'telephony' \
    "$MINIO_TELEPHONY_ACCESS_KEY" \
    "$MINIO_TELEPHONY_SECRET_KEY" \
    "$MINIO_TELEPHONY_BUCKETS" \
    "$MINIO_TELEPHONY_POLICY" \
    'Telephony' \
    's3:GetObject,s3:PutObject,s3:AbortMultipartUpload,s3:ListMultipartUploadParts'

# --- Сервисный аккаунт файлового сервиса (HAP-620) -------------------------------------
# file_service переезжает со своего отдельного MinIO (контейнер `file-s3` в его
# docker-compose) сюда, на общее хранилище. Решение — рекомендация architect-orchestrator
# в HAP-609: два инстанса на одной машине дают не изоляцию, а два цикла патчинга, бэкапа и
# мониторинга; настоящая граница — bucket + политика, а не отдельный процесс.
#
# Бакет — общий `documents`, тот же, что у диска `s3documents` CRM. Это решение владельца
# (HAP-620, 19.08.2026) и оно осознанное: фронт скачивает документы старым путём
# `GET /api/download/{file_path}?disk=s3documents`, то есть читает именно этот бакет.
# Сложив файлы file_service сюда, мы чиним скачивание сегодня, не дожидаясь мержа HAP-609
# (проксирование байтов через CRM) и HAP-616 (переключение фронта на id файла). Ключ
# объекта у file_service и `file_path` в ответе CRM — одна и та же строка, поэтому старый
# URL попадает точно в объект.
#
# ⚠️ Цена решения: бакет входит в политику `crm-app`, а она даёт запись и УДАЛЕНИЕ. То есть
# CRM технически может удалить документ должника мимо владельца данных. Изоляции по
# бакетам здесь нет — граница осталась только на уровне приложения. Предлагавшийся
# отдельный бакет `file-service` эту границу давал; вернуться к нему = поменять
# MINIO_FILES_BUCKETS и STORAGE_BUCKET у file_service, но тогда фронт ждёт HAP-609/616.
#
# Права те же, что у CRM (включая удаление): сервис управляет жизненным циклом файла —
# DELETE /api/v1/files/{id} обязан уносить и объект, иначе бакет копит осиротевшие файлы
# с ПДн, на которые уже никто не сошлётся, — а это ровно нарушение минимизации.
provision_account \
    'file-service' \
    "$MINIO_FILES_ACCESS_KEY" \
    "$MINIO_FILES_SECRET_KEY" \
    "$MINIO_FILES_BUCKETS" \
    "$MINIO_FILES_POLICY" \
    'FileService' \
    's3:GetObject,s3:PutObject,s3:DeleteObject,s3:AbortMultipartUpload,s3:ListMultipartUploadParts'

# --- Жизненный цикл бакета file_service (HAP-620) --------------------------------------
# Retention у документов должников и у записей разговоров разный, и полагаться на дефолт
# общего инстанса нельзя (требование architect-orchestrator к консолидации). Дефолта у
# MinIO, впрочем, никакого и нет: без правил не удаляется ничего и никогда.
#
#
# По умолчанию срок НЕ задан (MINIO_FILES_EXPIRE_DAYS пуст) — это не недоделка, а
# сознательный отказ придумывать число: автоудаление документа должника необратимо и
# должно опираться на регламент хранения, а не на дефолт из конфига. Механизм готов,
# включение — одна переменная, когда регламент назовут.
for b in $(echo "$MINIO_FILES_BUCKETS" | tr ',' ' '); do
    apply_lifecycle "$b" "$MINIO_FILES_EXPIRE_DAYS"
done
