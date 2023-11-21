### Разворачиваем Apache AirFlow в докере на LocalExecutor для запуска дагов:
- Клонируйте проект на свой компьютер:
```
git clone https://github.com/VladPronko/dags.git
```

- Создайте файл `variables` и добавьте в него переменные окружения для работы с дагами. Позже вы сможете импортировать их из данного файла с помощью вэб-интерфейса

- Добавьте необходимые зависимости в файл `requirements.txt`:
```
acryl-datahub[airflow]
airflow-clickhouse-plugin
pika
pytest-playwright
```

- Создайте файл `Dockerfile` и укажите в нем:
```dockerfile
FROM apache/airflow:2.7.3
COPY requirements.txt requirements.txt
RUN pip install --upgrade pip -r requirements.txt
```

- Запускаем сборку базового докер-образ с нашими зависимостями:
```
docker build -t airflow_with_requirements .
```
- Создайте файл `docker-compose.yaml` и укажите в нем:
```dockerfile
version: '3.8'
x-airflow-common:
  &airflow-common
  image: "airflow_with_requirements"
  environment:
    &airflow-common-env
    AIRFLOW__CORE__EXECUTOR: LocalExecutor
    AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
    # For backward compatibility, with Airflow <2.3
    AIRFLOW__CORE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
    AIRFLOW__CORE__FERNET_KEY: ''
    AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION: 'true'
    AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
    AIRFLOW__API__AUTH_BACKENDS: 'airflow.api.auth.backend.basic_auth,airflow.api.auth.backend.session'
    AIRFLOW__SCHEDULER__ENABLE_HEALTH_CHECK: 'true'
  volumes:
    - ${AIRFLOW_PROJ_DIR:-.}/dags:/opt/airflow/dags
    - ${AIRFLOW_PROJ_DIR:-.}/logs:/opt/airflow/logs
    - ${AIRFLOW_PROJ_DIR:-.}/config:/opt/airflow/config
    - ${AIRFLOW_PROJ_DIR:-.}/plugins:/opt/airflow/plugins
  user: "${AIRFLOW_UID:-50000}:0"
  depends_on:
    &airflow-common-depends-on
    postgres:
      condition: service_healthy

services:
  postgres:
    image: postgres:13
    environment:
      POSTGRES_USER: airflow
      POSTGRES_PASSWORD: airflow
      POSTGRES_DB: airflow
    volumes:
      - postgres-db-volume:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "airflow"]
      interval: 10s
      retries: 5
      start_period: 5s
    ports:
      - 5432:5432
    restart: always

  airflow-webserver:
    <<: *airflow-common
    command: webserver
    ports:
      - "8080:8080"
    healthcheck:
      test: ["CMD", "curl", "--fail", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    restart: always
    depends_on:
      <<: *airflow-common-depends-on
      airflow-init:
        condition: service_completed_successfully

  airflow-scheduler:
    <<: *airflow-common
    command: scheduler
    healthcheck:
      test: ["CMD", "curl", "--fail", "http://localhost:8974/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    restart: always
    depends_on:
      <<: *airflow-common-depends-on
      airflow-init:
        condition: service_completed_successfully

  airflow-triggerer:
    <<: *airflow-common
    command: triggerer
    healthcheck:
      test: ["CMD-SHELL", 'airflow jobs check --job-type TriggererJob --hostname "$${HOSTNAME}"']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    restart: always
    depends_on:
      <<: *airflow-common-depends-on
      airflow-init:
        condition: service_completed_successfully

  airflow-init:
    <<: *airflow-common
    entrypoint: /bin/bash
    # yamllint disable rule:line-length
    command:
      - -c
      - |
        function ver() {
          printf "%04d%04d%04d%04d" $${1//./ }
        }
        airflow_version=$$(AIRFLOW__LOGGING__LOGGING_LEVEL=INFO && gosu airflow airflow version)
        airflow_version_comparable=$$(ver $${airflow_version})
        min_airflow_version=2.2.0
        min_airflow_version_comparable=$$(ver $${min_airflow_version})
        if (( airflow_version_comparable < min_airflow_version_comparable )); then
          echo
          echo -e "\033[1;31mERROR!!!: Too old Airflow version $${airflow_version}!\e[0m"
          echo "The minimum Airflow version supported: $${min_airflow_version}. Only use this or higher!"
          echo
          exit 1
        fi
        if [[ -z "${AIRFLOW_UID}" ]]; then
          echo
          echo -e "\033[1;33mWARNING!!!: AIRFLOW_UID not set!\e[0m"
          echo "If you are on Linux, you SHOULD follow the instructions below to set "
          echo "AIRFLOW_UID environment variable, otherwise files will be owned by root."
          echo "For other operating systems you can get rid of the warning with manually created .env file:"
          echo "    See: https://airflow.apache.org/docs/apache-airflow/stable/howto/docker-compose/index.html#setting-the-right-airflow-user"
          echo
        fi
        one_meg=1048576
        mem_available=$$(($$(getconf _PHYS_PAGES) * $$(getconf PAGE_SIZE) / one_meg))
        cpus_available=$$(grep -cE 'cpu[0-9]+' /proc/stat)
        disk_available=$$(df / | tail -1 | awk '{print $$4}')
        warning_resources="false"
        if (( mem_available < 4000 )) ; then
          echo
          echo -e "\033[1;33mWARNING!!!: Not enough memory available for Docker.\e[0m"
          echo "At least 4GB of memory required. You have $$(numfmt --to iec $$((mem_available * one_meg)))"
          echo
          warning_resources="true"
        fi
        if (( cpus_available < 2 )); then
          echo
          echo -e "\033[1;33mWARNING!!!: Not enough CPUS available for Docker.\e[0m"
          echo "At least 2 CPUs recommended. You have $${cpus_available}"
          echo
          warning_resources="true"
        fi
        if (( disk_available < one_meg * 10 )); then
          echo
          echo -e "\033[1;33mWARNING!!!: Not enough Disk space available for Docker.\e[0m"
          echo "At least 10 GBs recommended. You have $$(numfmt --to iec $$((disk_available * 1024 )))"
          echo
          warning_resources="true"
        fi
        if [[ $${warning_resources} == "true" ]]; then
          echo
          echo -e "\033[1;33mWARNING!!!: You have not enough resources to run Airflow (see above)!\e[0m"
          echo "Please follow the instructions to increase amount of resources available:"
          echo "   https://airflow.apache.org/docs/apache-airflow/stable/howto/docker-compose/index.html#before-you-begin"
          echo
        fi
        mkdir -p /sources/logs /sources/dags /sources/plugins
        chown -R "${AIRFLOW_UID}:0" /sources/{logs,dags,plugins}
        exec /entrypoint airflow version
    environment:
      <<: *airflow-common-env
      _AIRFLOW_DB_MIGRATE: 'true'
      _AIRFLOW_WWW_USER_CREATE: 'true'
      _AIRFLOW_WWW_USER_USERNAME: ${_AIRFLOW_WWW_USER_USERNAME:-airflow}
      _AIRFLOW_WWW_USER_PASSWORD: ${_AIRFLOW_WWW_USER_PASSWORD:-airflow}
      _PIP_ADDITIONAL_REQUIREMENTS: ''
    user: "0:0"
    volumes:
      - ${AIRFLOW_PROJ_DIR:-.}:/sources

  airflow-cli:
    <<: *airflow-common
    profiles:
      - debug
    environment:
      <<: *airflow-common-env
      CONNECTION_CHECK_MAX_COUNT: "0"
    command:
      - bash
      - -c
      - airflow

volumes:
  postgres-db-volume:
```

- Запускаем airflow:
```
docker-compose up
```


### Разворачиваем Apache AirFlow локально на LocalExecutor для запуска дагов:
- Клонируйте проект на свой компьютер:
```
git clone https://github.com/VladPronko/dags.git
```

- Создайте файл `variables` и добавьте в него переменные окружения для работы с дагами. Позже вы сможете импортировать их из данного файла с помощью вэб-интерфейса

- Добавьте необходимые зависимости в файл `requirements.txt`:
```
acryl-datahub[airflow]
airflow-clickhouse-plugin
pika
pytest-playwright
pandas
apache-airflow-providers-postgres
```
- Создайте и активируйте виртуальное окружение:
```python
python3 -m venv venv
source venv/bin/activate
```
- Устанавливаем зависимости из файла requirements.txt:
```python
pip install --upgrade pip -r requirements.txt
```
- Укажим текущую директорию как основную для нашего airflow:
```bash
export AIRFLOW_HOME=`pwd`
```
- Устанавливаем airflow (выполняем построчно команды):
```bash
AIRFLOW_VERSION=2.7.3
PYTHON_VERSION="$(python --version | cut -d " " -f 2 | cut -d "." -f 1-2)"
CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
# For example this would install 2.7.3 with python 3.8: https://raw.githubusercontent.com/apache/airflow/constraints-2.7.3/constraints-3.8.txt
pip install "apache-airflow==${AIRFLOW_VERSION}" --constraint "${CONSTRAINT_URL}"
```
- Пробуем запустить airflow:
```python
airflow standalone
```
- После пробного запуска у нас в папке появился файл airflow.cfg. Заходим в него и исправляем параметры:
```
load_examples = False
load_default_connections = False
test_connection = Enabled
```
- Сбрасываем параметры БД:
```python
airflow db reset
```
- Загружаем переменные окружения через веб-интерфейс:
![image](https://github.com/VladPronko/dags/assets/88838807/59f29a50-7563-4c91-b774-844f1ea523e3)
![image](https://github.com/VladPronko/dags/assets/88838807/8e1d381a-c7c2-40ab-919d-539d223f73e7)
![image](https://github.com/VladPronko/dags/assets/88838807/f4fccd01-ccf5-4738-8471-74a3cb264cf9)

- Создаем файл docker-compose.yaml с параметрами postgres-БД для выполнения дагов:
```dockerfile
version: '3.8'
services:
  db:
    container_name: postgres-test
    image: postgres:14.5-alpine
    volumes:
      - db_data:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: ${POSTGRES_DB-test_db}
      POSTGRES_USER: ${POSTGRES_USER-test_user}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD-qwerty123}
    ports:
      - 5432:5432
  admin:
    image: adminer
    restart: always
    depends_on:
      - db
    ports:
      - 8888:8080
volumes:
  db_data:
```
- Запускаем docker-compose файл с БД:
```python
docker-compose up -d
```
- Запускаем airflow:
```python
airflow standalone
```
Идем в веб-интерфейс и создаем коннект к postgres-БД в докере:
![image](https://github.com/VladPronko/dags/assets/88838807/9c8f273d-ecbb-43eb-a43a-bd1fb20e390a)
![image](https://github.com/VladPronko/dags/assets/88838807/6d67173f-f343-4003-b78b-f9778122863b)

- Перезапускаем airflow и пользуемся:
```python
airflow standalone
```
