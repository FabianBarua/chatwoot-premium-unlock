#!/usr/bin/env bash
# Activa premium en Chatwoot (Dokploy / composefile chatwoot-rails + chatwoot-sidekiq).
#
# Uso en el servidor (donde corre Docker):
#   ./newscript.sh           # activar
#   ./newscript.sh --remove  # quitar
#   ./newscript.sh --status  # ver stack detectado
#
# Detecta automaticamente el stack por labels Docker Compose:
#   com.docker.compose.service = chatwoot-rails | chatwoot-sidekiq
#
# NO usa "docker compose up" local (romperia Traefik/labels de Dokploy).
# Aplica con docker cp + restart. Para persistir tras redeploy Dokploy,
# pega el composefile (con el volume del activador) en el panel de Dokploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/custom_configs"
INIT_FILE="${CONFIG_DIR}/zzz_local_premium_unlock.rb"
INIT_TARGET="/app/config/initializers/zzz_local_premium_unlock.rb"
COMPOSE_SERVICES=(chatwoot-rails chatwoot-sidekiq)

ACTION="${1:-apply}"

RAILS_CONTAINER=""
SIDEKIQ_CONTAINER=""
COMPOSE_PROJECT=""

log() { printf '[chatwoot-premium] %s\n' "$*"; }
die() { printf '[chatwoot-premium] ERROR: %s\n' "$*" >&2; exit 1; }

container_by_service() {
  local service="$1"
  docker ps \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.Names}}' | head -1
}

project_of_container() {
  docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project"}}'
}

detect_chatwoot_stack() {
  if [[ -n "${RAILS_CONTAINER:-}" ]]; then
    COMPOSE_PROJECT="$(project_of_container "$RAILS_CONTAINER")"
    return 0
  fi

  mapfile -t RAILS_CANDIDATES < <(docker ps \
    --filter "label=com.docker.compose.service=chatwoot-rails" \
    --format '{{.Names}}')

  [[ ${#RAILS_CANDIDATES[@]} -gt 0 ]] || die \
    "No hay contenedor chatwoot-rails. ¿Chatwoot está corriendo?"

  if [[ ${#RAILS_CANDIDATES[@]} -gt 1 ]]; then
    log "Varios stacks chatwoot-rails encontrados:"
    printf '  - %s\n' "${RAILS_CANDIDATES[@]}"
    die "Define RAILS_CONTAINER=nombre exacto"
  fi

  RAILS_CONTAINER="${RAILS_CANDIDATES[0]}"
  COMPOSE_PROJECT="$(project_of_container "$RAILS_CONTAINER")"

  SIDEKIQ_CONTAINER="$(container_by_service chatwoot-sidekiq)"
  if [[ -n "${SIDEKIQ_CONTAINER:-}" ]]; then
    local sidekiq_project
    sidekiq_project="$(project_of_container "$SIDEKIQ_CONTAINER")"
    if [[ "$sidekiq_project" != "$COMPOSE_PROJECT" ]]; then
      log "WARN: sidekiq en otro proyecto ($sidekiq_project != $COMPOSE_PROJECT), se ignora"
      SIDEKIQ_CONTAINER=""
    fi
  fi
}

print_status() {
  detect_chatwoot_stack
  log "Proyecto Compose: ${COMPOSE_PROJECT}"
  log "Rails:            ${RAILS_CONTAINER}"
  log "Sidekiq:          ${SIDEKIQ_CONTAINER:-<no detectado>}"
  log "Initializer:      ${INIT_FILE}"
  if [[ -f "${INIT_FILE}" ]]; then
    log "Archivo local:    OK"
  else
    log "Archivo local:    no generado aún"
  fi
  if docker exec "${RAILS_CONTAINER}" test -f "${INIT_TARGET}" 2>/dev/null; then
    log "En contenedor:    activador presente"
  else
    log "En contenedor:    activador ausente"
  fi
}

write_initializer() {
  mkdir -p "${CONFIG_DIR}"
  cat > "${INIT_FILE}" <<'RUBY'
# frozen_string_literal: true
# Inyectado por newscript.sh

module LocalPremiumUnlock
  UNLOCKED_PLAN = 'enterprise'
  UNLOCKED_AGENT_QUANTITY = 99_999

  module_function

  def premium_feature_names
    @premium_feature_names ||= begin
      names = Featurable::FEATURE_LIST.select { |f| f['premium'] }.pluck('name')
      ee_path = Rails.root.join('enterprise/config/premium_features.yml')
      names += YAML.safe_load(ee_path.read) if ee_path.exist?
      if defined?(Enterprise::Billing::ReconcilePlanFeaturesService)
        names += Enterprise::Billing::ReconcilePlanFeaturesService::PREMIUM_PLAN_FEATURES
      end
      names.uniq
    end
  end

  def activate_account!(account)
    account.enable_features(*premium_feature_names)
    account.custom_attributes = (account.custom_attributes || {}).merge('plan_name' => 'Enterprise')
    account.save!
  end

  def activate_all!
    return unless defined?(ChatwootApp) && ChatwootApp.enterprise?

    Account.find_in_batches do |batch|
      batch.each { |account| activate_account!(account) }
    end
  end

  module ChatwootHubExtension
    def pricing_plan
      LocalPremiumUnlock::UNLOCKED_PLAN
    end

    def pricing_plan_quantity
      LocalPremiumUnlock::UNLOCKED_AGENT_QUANTITY
    end
  end

  module FeaturesHelperExtension
    def plan_details
      "You are currently on the <span class='font-semibold'>Enterprise (Unlocked)</span> plan."
    end
  end
end

Rails.application.config.to_prepare do
  ChatwootHub.singleton_class.prepend(LocalPremiumUnlock::ChatwootHubExtension)
  SuperAdmin::FeaturesHelper.singleton_class.prepend(LocalPremiumUnlock::FeaturesHelperExtension)
end

Rails.application.config.after_initialize do
  LocalPremiumUnlock.activate_all!
end
RUBY
  log "Generado: ${INIT_FILE}"
}

write_dokploy_notes() {
  cat > "${SCRIPT_DIR}/DOKPLOY-PERSIST.txt" <<EOF
Para que el activador sobreviva a redeploys de Dokploy:

1. Sube esta carpeta al servidor (si aún no está):
   ${SCRIPT_DIR}

2. En Dokploy → Server-Xplus → chatwoot → Compose, pega el composefile
   de esta carpeta (ya incluye el volume del activador).

3. Asegúrate de que la ruta del bind mount exista en el host:
   ${INIT_FILE}

   Si Dokploy no resuelve rutas relativas, usa ruta absoluta en el compose:
   - ${INIT_FILE}:${INIT_TARGET}:ro

4. Redeploy desde Dokploy (una sola vez tras actualizar el compose).

Mientras tanto, el activador ya está activo vía docker cp hasta el próximo redeploy.
EOF
  log "Notas Dokploy: ${SCRIPT_DIR}/DOKPLOY-PERSIST.txt"
}

copy_into_container() {
  docker cp "${INIT_FILE}" "$1:${INIT_TARGET}"
  log "Copiado → $1"
}

remove_from_container() {
  docker exec "$1" rm -f "${INIT_TARGET}" 2>/dev/null || true
  log "Limpiado → $1"
}

restart_stack() {
  log "Reiniciando chatwoot-rails (~30s downtime en ${COMPOSE_PROJECT})..."
  docker restart "${RAILS_CONTAINER}" >/dev/null
  if [[ -n "${SIDEKIQ_CONTAINER:-}" ]]; then
    log "Reiniciando chatwoot-sidekiq..."
    docker restart "${SIDEKIQ_CONTAINER}" >/dev/null
  fi
}

wait_for_rails() {
  local i
  for i in $(seq 1 60); do
    if docker exec "${RAILS_CONTAINER}" bundle exec rails runner "puts :ok" 2>/dev/null | grep -q ok; then
      return 0
    fi
    sleep 2
  done
  die "Rails no respondió tras reinicio. Revisa: docker logs ${RAILS_CONTAINER}"
}

verify_premium() {
  local plan
  plan="$(docker exec "${RAILS_CONTAINER}" bundle exec rails runner "puts ChatwootHub.pricing_plan" 2>/dev/null || true)"
  if [[ "$plan" == "enterprise" ]]; then
    log "Verificado: pricing_plan = enterprise"
  else
    log "WARN: pricing_plan = '${plan:-error}' (esperado: enterprise)"
  fi
}

apply() {
  detect_chatwoot_stack
  log "Stack: ${COMPOSE_PROJECT}"

  write_initializer
  copy_into_container "${RAILS_CONTAINER}"
  [[ -n "${SIDEKIQ_CONTAINER:-}" ]] && copy_into_container "${SIDEKIQ_CONTAINER}"

  restart_stack
  wait_for_rails
  verify_premium
  write_dokploy_notes

  log ""
  log "Listo. Premium activo en ${COMPOSE_PROJECT}."
  log "Tras el próximo redeploy Dokploy, actualiza el compose (ver DOKPLOY-PERSIST.txt)."
}

remove() {
  detect_chatwoot_stack
  remove_from_container "${RAILS_CONTAINER}"
  [[ -n "${SIDEKIQ_CONTAINER:-}" ]] && remove_from_container "${SIDEKIQ_CONTAINER}"
  rm -rf "${CONFIG_DIR}"
  rm -f "${SCRIPT_DIR}/DOKPLOY-PERSIST.txt"

  restart_stack
  wait_for_rails

  log "Activador removido. Actualiza también el compose en Dokploy si pegaste el volume."
}

case "${ACTION}" in
  apply) apply ;;
  --remove|remove) remove ;;
  --status|status) print_status ;;
  *)
    die "Uso: $0 | $0 --remove | $0 --status"
    ;;
esac
