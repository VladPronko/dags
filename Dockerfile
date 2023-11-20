FROM apache/airflow:2.7.3
# FROM apache/airflow:2.6.3

# this fixes a warning in the official image, with the Azure provider
# More info here https://github.com/apache/airflow/issues/14266#issuecomment-786298240
RUN pip uninstall  --yes azure-storage && pip install -U azure-storage-blob apache-airflow-providers-microsoft-azure

COPY requirements.txt requirements.txt

RUN pip install --upgrade pip -r requirements.txt