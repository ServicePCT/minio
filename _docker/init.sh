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
MINIO_BUCKETS="${MINIO_BUCKETS:-registry,record,whatsapp,documents,chat-attachments,role-profiles}"

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
# Бакет(ы) записей разговоров, где живут раздельные дорожки STT `in_`/`out_` (HAP-2952).
# По умолчанию — тот же бакет, что у учётки телефонии: это и есть бакет записей ИНСТАЛЛЯЦИИ
# (`record` на машине с нуля, `records` там, куда перенесён старый контур, HAP-1148).
MINIO_STT_TRACKS_BUCKETS="${MINIO_STT_TRACKS_BUCKETS:-$MINIO_TELEPHONY_BUCKETS}"
# Срок жизни дорожек в днях. Пусто = дорожки хранятся бессрочно, правило не ставится.
# Решение владельца (HAP-2952, 21.11.2026): это величина инсталляции, а не константа. Там,
# где за большой период накоплены дорожки, их можно распознать задним числом и приложить
# транскрибацию к записям — правило с первой выкатки стёрло бы всё, кроме последних дней.
MINIO_STT_TRACKS_EXPIRE_DAYS="${MINIO_STT_TRACKS_EXPIRE_DAYS:-}"

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
# Пустой набор правил = конфигурация бакета не трогается.
#
# Идемпотентность — через `mc ilm rule import`: он ЗАМЕНЯЕТ конфигурацию бакета целиком
# тем, что подали на вход. `mc ilm rule add` при каждом прогоне добавлял бы ещё одно
# правило с новым сгенерированным ID, и после десятка выкаток в бакете лежала бы стопка
# дублей — а скрипт гоняется на каждой выкатке.
#
# Из-за той же замены правила собираются ПО БАКЕТУ, а не по источнику: если один бакет
# попадёт и в MINIO_FILES_BUCKETS, и в MINIO_STT_TRACKS_BUCKETS, два отдельных import'а
# стёрли бы друг друга, и выжило бы то правило, что применено последним (HAP-2952).
#
# ⚠️ Обратная сторона замены: правило, заведённое руками через консоль, следующая выкатка
# сотрёт. Правила живут здесь, в коде, — как и сами аккаунты. Снять правило = убрать его
# источник здесь/в .env И один раз выполнить `mc ilm rule rm --all --force local/<бакет>`:
# пустой список сюда сознательно не подаётся, чтобы опечатка в переменной не обнулила
# молча жизненный цикл работающего бакета.
#
# ⚠️ Правила на брошенные multipart-загрузки здесь НЕТ намеренно, хотя в S3 такое действие
# есть (AbortIncompleteMultipartUpload). MinIO его в lifecycle не принимает — отвечает
# «XML ... did not validate against our published schema», и флага под него нет даже в
# `mc ilm rule add` (проверено 19.08.2026 на RELEASE.2025-09-07 + mc RELEASE.2025-04-16).
# Убирает их сам сервер: `mc admin config get <alias> api` → stale_uploads_expiry=24h,
# stale_uploads_cleanup_interval=6h. То есть проблема решена, просто не здесь.

# Входит ли элемент $1 в список через запятую $2.
in_list() {
    case ",$2," in
        *",$1,"*) return 0 ;;
    esac
    return 1
}

# Правила для бакета $1 — JSON-объекты через запятую (может быть пусто).
lifecycle_rules() {
    bucket="$1"
    rules=''

    # Бакет file_service (HAP-620): весь бакет, срок из MINIO_FILES_EXPIRE_DAYS.
    if [ -n "$MINIO_FILES_EXPIRE_DAYS" ] && in_list "$bucket" "$MINIO_FILES_BUCKETS"; then
        rules="{\"ID\":\"expire-objects\",\"Status\":\"Enabled\",\"Expiration\":{\"Days\":$MINIO_FILES_EXPIRE_DAYS}}"
    fi

    # Бакет записей (HAP-2952): только префиксы дорожек STT. Запись `both_*` и всё прочее
    # правило не задевает — фильтр Prefix в S3 сравнивает начало ключа буквально.
    if [ -n "$MINIO_STT_TRACKS_EXPIRE_DAYS" ] && in_list "$bucket" "$MINIO_STT_TRACKS_BUCKETS"; then
        for p in in out; do
            rules="${rules:+$rules,}{\"ID\":\"expire-stt-tracks-$p\",\"Status\":\"Enabled\",\"Filter\":{\"Prefix\":\"${p}_\"},\"Expiration\":{\"Days\":$MINIO_STT_TRACKS_EXPIRE_DAYS}}"
        done
    fi

    printf '%s' "$rules"
}

apply_lifecycle() {
    bucket="$1"

    # Бакет может быть не заведён: на хосте список бакетов задан в .env явным значением и
    # не обязан совпадать с дефолтом из репозитория (HAP-539). Правило на несуществующий
    # бакет — ошибка, поэтому создаём здесь же.
    mc mb --ignore-existing "local/$bucket" >/dev/null

    rules="$(lifecycle_rules "$bucket")"
    if [ -z "$rules" ]; then
        echo "lifecycle: $bucket — правил нет, конфигурация не менялась"
        return 0
    fi

    ilm_file="/tmp/$bucket-ilm.json"
    printf '{"Rules":[%s]}' "$rules" > "$ilm_file"
    mc ilm rule import "local/$bucket" < "$ilm_file" >/dev/null
    echo "lifecycle ready: $bucket — $rules"
}

# --- Сервисный аккаунт CRM (HAP-509) ---------------------------------------------------
# Чтение и запись в свои бакеты, включая удаление: CRM управляет жизненным циклом
# загруженных документов и файлов WhatsApp.
#
# HAP-1166: сюда же добавлен `role-profiles` — снапшоты профилей ролей (`roles:export`,
# контракт HAP-1164). Потребитель тот же, CRM, поэтому новой учётки нет: аккаунт заводится
# на СЕРВИС, а не на бакет. ПДн в этих файлах нет по построению — только роли, группы и
# ключи прав, без пользователей и без `role_user`.
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
# Подтверждено решением владельца в HAP-2952 (21.11.2026), в том числе для дорожек STT
# `in_*`/`out_*`: узкое право удаления только на эти префиксы предлагалось и было ОТКЛОНЕНО.
# Удаление дорожек из R2 telephony-ari по тому же решению убирается совсем: сервис объекты в
# MinIO не удаляет. Судьбу дорожек решает только MINIO_STT_TRACKS_EXPIRE_DAYS ниже —
# бессрочно по умолчанию или удаление через N дней.
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
#
# --- Жизненный цикл дорожек STT в бакете записей (HAP-2952) ----------------------------
# Страховка к M-2 из ревью HAP-2950. Для STT телефония кладёт рядом с записью разговора
# `both_<protocol_id>.mp3` (её слушает CRM) ещё две раздельные дорожки —
# `in_<protocol_id>.wav` и `out_<protocol_id>.wav`, в корень бакета. Начиная с R2
# (telephony-ari, HAP-2938) их удаляет сам `ari-file-service`: после done/failed задачи на
# общем STT, сразу при постоянной ошибке отправки и в любом случае не позже 48 ч. Если
# сервис долго лежит или очередь `stt_submit` потеряна, дорожки — запись разговора, ПДн —
# остались бы в хранилище навсегда. Правило снимает эту зависимость.
#
# Срок задаётся на инсталляции (MINIO_STT_TRACKS_EXPIRE_DAYS), по умолчанию ПУСТ — дорожки
# хранятся бессрочно, правило не ставится. Решение владельца (HAP-2952, 21.11.2026): там,
# где дорожки накоплены за большой период, их собираются распознать задним числом, и
# правило с первой выкатки стёрло бы всё старше срока. Рекомендуемое значение там, где
# архив не нужен, — 7 (решение владельца). Меньше 2 ставить нельзя: presigned-ссылка для
# STT живёт до 24 ч плюс очередь, раньше — сорвётся скачивание. ⚠️ MinIO считает Days до
# ближайшей полуночи UTC и удаляет фоновым сканером: фактически +1 сутки к сроку.
#
# На инсталляциях со старым путём дорожки по-прежнему удаляет stt_service сразу после
# обработки — правило ему не мешает, оно лишь подбирает то, что осталось.
#
# 🔴 Включение срока = первый проход сканера удалит ВСЕ уже лежащие `in_*`/`out_*` старше
# срока, необратимо. Прежде чем вписать число, решите, нужен ли накопленный архив.
#
# 🔴 Записи `both_*` хранятся по закону БЕССРОЧНО (решение владельца, HAP-2952). Правило
# дорожек их не задевает (фильтр по префиксу). Опасен другой путь: правило «удалять всё»
# из MINIO_FILES_EXPIRE_DAYS, если бакет записей по ошибке окажется в MINIO_FILES_BUCKETS.
# Такую конфигурацию отвергаем целиком, ДО применения каких-либо правил.
if [ -n "$MINIO_STT_TRACKS_EXPIRE_DAYS" ]; then
    case "$MINIO_STT_TRACKS_EXPIRE_DAYS" in
        *[!0-9]*) echo "lifecycle: ОШИБКА — MINIO_STT_TRACKS_EXPIRE_DAYS должен быть числом дней или пустым" >&2; exit 1 ;;
    esac
    if [ "$MINIO_STT_TRACKS_EXPIRE_DAYS" -lt 2 ]; then
        echo "lifecycle: ОШИБКА — MINIO_STT_TRACKS_EXPIRE_DAYS < 2: дорожка исчезнет раньше, чем её скачает STT" >&2
        exit 1
    fi
fi
if [ -n "$MINIO_FILES_EXPIRE_DAYS" ]; then
    for b in $(echo "$MINIO_TELEPHONY_BUCKETS,$MINIO_STT_TRACKS_BUCKETS" | tr ',' ' '); do
        if in_list "$b" "$MINIO_FILES_BUCKETS"; then
            echo "lifecycle: ОШИБКА — бакет записей $b входит в MINIO_FILES_BUCKETS при заданном MINIO_FILES_EXPIRE_DAYS: правило удалило бы записи both_*, которые хранятся бессрочно" >&2
            exit 1
        fi
    done
fi

# Бакеты обходим объединённым списком без повторов: правила собираются по бакету (см.
# lifecycle_rules), и один бакет не должен обрабатываться дважды.
seen=''
for b in $(echo "$MINIO_FILES_BUCKETS,$MINIO_STT_TRACKS_BUCKETS" | tr ',' ' '); do
    in_list "$b" "$seen" && continue
    seen="${seen:+$seen,}$b"
    apply_lifecycle "$b"
done
