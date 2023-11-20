FROM apache/airflow:2.7.3

COPY requirements.txt requirements.txt

RUN pip install --upgrade pip -r requirements.txt