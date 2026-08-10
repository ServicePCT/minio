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
