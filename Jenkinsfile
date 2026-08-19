// minio — CI/CD (HAP-404, онбординг в новый Jenkins).
//
// Конфигурация сборки живёт ЗДЕСЬ, в репозитории проекта, а не в настройках Jenkins —
// требование HAP-388. Общие шаги (composeDeploy/notify) — в библиотеке happydebt:
// https://github.com/ServicePCT/jenkins-shared-library
//
// У minio нет ни своей сборки, ни тестов: это готовый образ с конфигурацией. Поэтому
// pipeline короткий — только выкатка и проверка, что стек поднялся.

@Library('happydebt') _

pipeline {
    agent any

    environment {
        // Ключи выкатки — из хранилища ПАПКИ `crm`, а не из общего (HAP-500). Общий
        // deploy-staging-ssh виден сборке любого подключённого проекта: сборка исполняет
        // Jenkinsfile из своего репозитория, и запросить чужой credential по id ей ничто
        // не мешает.
        // Папка общая с crm, и это не про предметную область: CRM ходит в это хранилище ROOT-кредами
        // MinIO, то есть держит их у себя в .env. Отдельная папка нарисовала бы границу, которой
        // нет; своя появится, когда у CRM будет сервисный аккаунт вместо root.
        DEPLOY_CREDENTIALS_ID = 'deploy-crm-staging-ssh'
        // Прод-ключа ещё нет — как и прод-хоста. Идентификатор проставлен заранее, чтобы
        // первая прод-выкатка упала с «credential not found», а не уехала на боевую машину
        // стендовым ключом.
        PROD_CREDENTIALS_ID   = 'deploy-crm-prod-ssh'
    }

    parameters {
        // Целевые хосты — параметрами с дефолтами прямо здесь.
        // ⚠️ При смене дефолта помните: Jenkins применяет новое значение со ВТОРОЙ сборки
        // (см. jenkins-infra/DEPLOY.md §10). После правки прогоните сборку дважды.
        string(name: 'STAGING_HOST', defaultValue: 'prog@vm-stage.happydebt.kz', description: 'user@host стенда; пусто — выкатка пропускается')
        string(name: 'STAGING_PATH', defaultValue: '/srv/minio', description: 'каталог с docker-compose.yml на стенде')
        string(name: 'PROD_HOST',    defaultValue: '', description: 'user@host прода; пусто — выкатка пропускается')
        string(name: 'PROD_PATH',    defaultValue: '/srv/minio', description: 'каталог с docker-compose.yml на проде')
    }

    options {
        timeout(time: 20, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timestamps()
        // Две выкатки хранилища одновременно — гонка на целевом хосте.
        disableConcurrentBuilds()
    }

    stages {
        stage('проверка конфигурации') {
            steps {
                // Своих тестов у проекта нет, но синтаксис compose проверить стоит: сломанный
                // YAML лучше поймать здесь, чем на целевом хосте в середине выкатки.
                //
                // Обязательные переменные подставляем заглушками прямо здесь. Через
                // --env-file .env.example не выйдет: там пароли намеренно пустые, а
                // ${VAR:?} на пустом значении уронит проверку. Реальные секреты в CI не
                // нужны — `config` только раскрывает подстановки и проверяет структуру.
                sh '''
                    set -eu
                    MINIO_ROOT_USER=ci-check \
                    MINIO_ROOT_PASSWORD=ci-check-placeholder \
                    docker compose -f docker-compose.yml config >/dev/null
                    echo "docker-compose.yml валиден"

                    # Скрипт инициализации исполняется на целевом хосте внутри контейнера
                    # mc, где отладчика нет и логи видны только постфактум. Синтаксис
                    # ловим здесь: ошибка в нём означает стек без бакетов и без учётки CRM.
                    sh -n _docker/init.sh
                    echo "_docker/init.sh валиден"
                '''
            }
        }

        stage('deploy staging') {
            when {
                allOf {
                    // Имя основной ветки у наших репозиториев разное (у minio — dev),
                    // поэтому опираемся на флаг branch-api, а не на литерал.
                    expression { env.BRANCH_IS_PRIMARY == 'true' }
                    expression { params.STAGING_HOST?.trim() }
                }
            }
            steps {
                composeDeploy(
                    env: 'staging',
                    host: params.STAGING_HOST,
                    path: params.STAGING_PATH,
                    credentialsId: env.DEPLOY_CREDENTIALS_ID,
                    // Ключи сервисного аккаунта CRM (HAP-509) — из хранилища папки `crm`,
                    // а не копипастой в .env на хосте. Именно копипаста пароля между
                    // .env разных сервисов и породила три копии одного секрета: ротация
                    // в источнике до хоста не доезжала. Теперь источник один, а разносит
                    // значения выкатка (jenkins-infra/DEPLOY.md §10).
                    //
                    // Сами root-креды хранилища сюда НЕ едут: они на хосте с самого
                    // начала, и подменять их из CI — отдельное решение с отдельным риском
                    // (не тот пароль в .env = хранилище не поднимется).
                    //
                    // Ключи сервисного аккаунта телефонии (HAP-516) лежат в этом же
                    // хранилище, хотя сам telephony-ari живёт в папке `telephony`:
                    // credential виден тому, кто заводит учётку (minio, папка `crm`), а
                    // до потребителя те же значения едут своим путём — Secret-file
                    // credential'ом `telephony-ari-staging-env` папки `telephony`.
                    // Держать их в папке `telephony` нельзя: оттуда их не прочитала бы
                    // сборка minio, а без неё аккаунт просто не заведётся.
                    //
                    // Ключи сервисного аккаунта file_service (HAP-620) лежат там же и по
                    // той же причине: сборка minio заводит учётку, а до потребителя те же
                    // значения едут выкаткой file_service. Credential'ы заведены
                    // 19.08.2026 (jenkins-infra, SPEC папки `crm`) — без них эта строка
                    // уронила бы выкатку хранилища на «credential not found».
                    envSecrets: [
                        MINIO_CRM_ACCESS_KEY: 'crm-minio-access-key',
                        MINIO_CRM_SECRET_KEY: 'crm-minio-secret-key',
                        MINIO_TELEPHONY_ACCESS_KEY: 'minio-telephony-access-key',
                        MINIO_TELEPHONY_SECRET_KEY: 'minio-telephony-secret-key',
                        MINIO_FILES_ACCESS_KEY: 'minio-files-access-key',
                        MINIO_FILES_SECRET_KEY: 'minio-files-secret-key',
                    ],
                    approve: false
                )
            }
        }

        stage('deploy prod') {
            when {
                allOf {
                    expression { env.BRANCH_IS_PRIMARY == 'true' }
                    expression { params.PROD_HOST?.trim() }
                }
            }
            steps {
                // 🔴 Прод — только с явного подтверждения. В хранилище лежат записи разговоров
                // и файлы WhatsApp; перезапуск означает недоступность файлов для всех
                // сервисов, которые в него ходят.
                composeDeploy(
                    env: 'prod',
                    host: params.PROD_HOST,
                    path: params.PROD_PATH,
                    credentialsId: env.PROD_CREDENTIALS_ID,
                    // У стенда и прода credential'ы РАЗНЫЕ: общий означал бы стендовый
                    // ключ на боевом хранилище. Прод-credential'ов ещё нет — как и
                    // прод-хоста; идентификаторы проставлены заранее, чтобы первая
                    // прод-выкатка упала с «credential not found», а не завела на боевом
                    // MinIO учётку со стендовым ключом.
                    envSecrets: [
                        MINIO_CRM_ACCESS_KEY: 'crm-minio-access-key-prod',
                        MINIO_CRM_SECRET_KEY: 'crm-minio-secret-key-prod',
                        MINIO_TELEPHONY_ACCESS_KEY: 'minio-telephony-access-key-prod',
                        MINIO_TELEPHONY_SECRET_KEY: 'minio-telephony-secret-key-prod',
                        MINIO_FILES_ACCESS_KEY: 'minio-files-access-key-prod',
                        MINIO_FILES_SECRET_KEY: 'minio-files-secret-key-prod',
                    ],
                    approve: true
                )
            }
        }
    }

    post {
        always  { notify(currentBuild.currentResult) }
        cleanup { cleanWs() }
    }
}
