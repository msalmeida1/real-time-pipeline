# Serverless Real-Time Music Analytics Pipeline

# 🎵 Spotify Real-Time Serverless Analytics

Este projeto é uma implementação prática de uma arquitetura de ingestão e processamento de dados em tempo real utilizando serviços **AWS Serverless**.

O objetivo é simular o cenário de grandes empresas de mídia (como Netflix ou Spotify) que precisam rastrear o engajamento do usuário (Clickstream/Telemetry) instantaneamente para gerar recomendações ou análises de comportamento, lidando com picos de tráfego de forma elástica.

---

## Arquitetura da solução

A solução segue o padrão **Producer-Consumer** com desacoplamento via Stream:

1.  **Data Producer (Python):** Um script local consulta a API do Spotify (`current-user-playing`) periodicamente para capturar o que está tocando.
2.  **Ingestão (Amazon Kinesis Data Streams):** Atua como buffer de alta velocidade, recebendo os eventos brutos e garantindo a durabilidade dos dados mesmo em picos de escrita.
3.  **Processamento (AWS Lambda):** Função serverless acionada automaticamente (Trigger) a cada novo lote de registros no Kinesis. Ela processa a lógica de negócio (ex: detectar se a música foi pulada "Skip" ou ouvida até o fim).
4.  **Armazenamento (Amazon DynamoDB):** Banco NoSQL utilizado para persistir as métricas processadas com baixa latência.

### Diagrama Lógico
`Spotify API` ➔ `Python Script` ➔ **`Kinesis Data Stream`** ➔ **`AWS Lambda`** ➔ **`DynamoDB`**

---

## 🛠 Tecnologias Utilizadas

* **Linguagem:** Python 3.9+
* **IAC:** Terraform
* **AWS Services:**
    * Kinesis Data Streams (Ingestão)
    * Lambda (Processamento Serverless)
    * DynamoDB (Banco NoSQL)
    * IAM (Gestão de Permissões e Roles)
    * CloudWatch (Logs e Monitoramento)
* **Libs:** `boto3` (AWS SDK), `spotipy` (Spotify wrapper)

---