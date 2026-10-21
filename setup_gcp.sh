#!/usr/bin/env bash
# =============================================================================
# setup_gcp.sh
# -----------------------------------------------------------------------------
# Prepara a infraestrutura de streaming no GCP (rodar UMA vez, no Cloud Shell):
#   1. habilita as APIs necessárias
#   2. cria o tópico do Pub/Sub e duas assinaturas:
#        - crimes-chicago-dataflow-sub : consumida pelo pipeline (Beam/Dataflow)
#        - crimes-chicago-debug-sub    : só para inspecionar mensagens na demo
#   3. cria uma service account para o Dataflow com o mínimo de permissões
#
# Por que duas assinaturas? Cada assinatura recebe uma CÓPIA de todas as
# mensagens do tópico. Assim dá para espiar o tópico (debug-sub) sem "roubar"
# mensagens do pipeline.
#
# O script é idempotente na prática: se um recurso já existe, o gcloud avisa e
# o script segue em frente.
# =============================================================================
set -u

PROJECT="pdm-crimes-chicago"
REGION="us-central1"
BUCKET="crimes-chicago-pdm-2026"
TOPIC="crimes-chicago"
SUB_PIPELINE="crimes-chicago-dataflow-sub"
SUB_DEBUG="crimes-chicago-debug-sub"
SA_NAME="sa-streaming"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

gcloud config set project "$PROJECT"

echo ">> Habilitando APIs"
gcloud services enable \
  pubsub.googleapis.com \
  dataflow.googleapis.com \
  bigquery.googleapis.com \
  compute.googleapis.com \
  storage.googleapis.com

echo ">> Criando tópico e assinaturas"
gcloud pubsub topics create "$TOPIC"
gcloud pubsub subscriptions create "$SUB_PIPELINE" \
  --topic="$TOPIC" --ack-deadline=60 --message-retention-duration=1d
gcloud pubsub subscriptions create "$SUB_DEBUG" \
  --topic="$TOPIC" --message-retention-duration=1d

echo ">> Criando service account do pipeline"
gcloud iam service-accounts create "$SA_NAME" \
  --display-name="Streaming Chicago Crimes (Dataflow worker)"

for ROLE in roles/dataflow.worker roles/pubsub.subscriber roles/pubsub.viewer \
            roles/bigquery.dataEditor roles/bigquery.jobUser; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --condition=None >/dev/null
done

# acesso ao bucket usado para arquivos temporários do Dataflow
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/storage.objectAdmin"

echo
echo "Pronto. Próximos passos:"
echo "  1) rodar sql/10_stream_tables.sql no BigQuery"
echo "  2) python producer/producer.py --salvar-cache eventos.jsonl   (baixa os dados da API)"
echo "  3) lançar o pipeline (ver README.md desta pasta)"
echo "  4) python producer/producer.py --cache eventos.jsonl --rate 10"
echo
echo "Verificar o tópico:  gcloud pubsub topics list"
echo "Espiar mensagens:    gcloud pubsub subscriptions pull $SUB_DEBUG --limit=3 --auto-ack"
