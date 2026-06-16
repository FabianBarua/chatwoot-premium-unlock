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
# Aplica: escribe el .rb en el host + restart.
# Sin volume en Dokploy: docker cp al contenedor.
# Con volume montado: solo host + restart (docker cp falla: "device or resource busy").

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

ensure_init_file_path() {
  if [[ -d "${INIT_FILE}" ]]; then
    log "WARN: ${INIT_FILE} es un directorio — eliminando..."
    if ! rm -rf "${INIT_FILE}"; then
      die "No se pudo borrar. Para chatwoot en Dokploy, redeploy sin el volume, luego ./newscript.sh"
    fi
  fi
  if [[ -e "${INIT_FILE}" && ! -f "${INIT_FILE}" ]]; then
    die "${INIT_FILE} existe pero no es un archivo regular"
  fi
}

prepare_host_initializer() {
  mkdir -p "${CONFIG_DIR}"
  ensure_init_file_path
}

print_status() {
  detect_chatwoot_stack
  log "Proyecto Compose: ${COMPOSE_PROJECT}"
  log "Rails:            ${RAILS_CONTAINER}"
  log "Sidekiq:          ${SIDEKIQ_CONTAINER:-<no detectado>}"
  log "Initializer:      ${INIT_FILE}"
  if [[ -f "${INIT_FILE}" ]]; then
    log "Archivo local:    OK"
  elif [[ -d "${INIT_FILE}" ]]; then
    log "Archivo local:    ERROR (es un directorio — ejecuta ./newscript.sh para corregir)"
  else
    log "Archivo local:    no generado aún"
  fi
  local mount_source
  mount_source="$(init_bind_mount_source "${RAILS_CONTAINER}")"
  if [[ -n "${mount_source}" ]]; then
    log "Deploy:           volume bind-mount (persistente)"
    log "Mount host:       ${mount_source}"
  else
    log "Deploy:           docker cp (sin volume en compose)"
  fi
  if docker exec "${RAILS_CONTAINER}" test -f "${INIT_TARGET}" 2>/dev/null; then
    log "En contenedor:    activador presente"
  else
    log "En contenedor:    activador ausente"
  fi
}

write_initializer() {
  prepare_host_initializer
  cat > "${INIT_FILE}" <<'RUBY'
# frozen_string_literal: true
# Inyectado por newscript.sh

module LocalPremiumUnlock
  UNLOCKED_PLAN = 'enterprise'
  UNLOCKED_AGENT_QUANTITY = 99_999
  CAPTAIN_FEATURES = %w[
    captain_integration
    captain_integration_v2
    captain_tasks
    custom_tools
    captain_document_auto_sync
  ].freeze

  module_function

  def unlock_installation_plan!
    %w[INSTALLATION_PRICING_PLAN INSTALLATION_PRICING_PLAN_QUANTITY].each do |name|
      config = InstallationConfig.find_or_initialize_by(name: name)
      config.value = name == 'INSTALLATION_PRICING_PLAN_QUANTITY' ? UNLOCKED_AGENT_QUANTITY : UNLOCKED_PLAN
      config.save!
    end
    GlobalConfig.clear_cache
  end

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
    account.enable_features(*(premium_feature_names + CAPTAIN_FEATURES))
    account.custom_attributes = (account.custom_attributes || {}).merge('plan_name' => 'Enterprise')
  end

  def activate_captain_preferences!(account)
    defaults = Llm::Models.feature_keys.index_with { true }
    account.captain_features = (account.captain_features || {}).merge(defaults)
    account.save!
  end

  def activate_all!
    return unless defined?(ChatwootApp) && ChatwootApp.enterprise?

    Account.find_in_batches do |batch|
      batch.each do |account|
        activate_account!(account)
        activate_captain_preferences!(account)
      end
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
  LocalPremiumUnlock.unlock_installation_plan!
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

init_bind_mount_source() {
  local container="$1"
  docker inspect "$container" \
    --format '{{range .Mounts}}{{if eq .Destination "'"${INIT_TARGET}"'"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true
}

deploy_initializer_to_container() {
  local container="$1"
  local mount_source
  mount_source="$(init_bind_mount_source "$container")"
  if [[ -n "${mount_source}" ]]; then
    log "Volume montado en ${container} — omitiendo docker cp"
    log "  host: ${mount_source}"
    return 0
  fi
  docker cp "${INIT_FILE}" "${container}:${INIT_TARGET}"
  log "Copiado → ${container}"
}

remove_from_container() {
  local container="$1"
  if [[ -n "$(init_bind_mount_source "$container")" ]]; then
    log "Volume montado en ${container} — se limpia solo el archivo en host"
    return 0
  fi
  docker exec "$container" rm -f "${INIT_TARGET}" 2>/dev/null || true
  log "Limpiado → ${container}"
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
  local plan install_plan
  plan="$(
    docker exec "${RAILS_CONTAINER}" bundle exec rails runner \
      "puts ChatwootHub.pricing_plan" 2>/dev/null \
      | grep -E '^(enterprise|community|premium)$' \
      | tail -1 \
      || true
  )"
  install_plan="$(
    docker exec "${RAILS_CONTAINER}" bundle exec rails runner \
      "puts GlobalConfig.get_value('INSTALLATION_PRICING_PLAN')" 2>/dev/null \
      | grep -E '^(enterprise|community|premium)$' \
      | tail -1 \
      || true
  )"
  if [[ "$plan" == "enterprise" && "$install_plan" == "enterprise" ]]; then
    log "Verificado: pricing_plan + INSTALLATION_PRICING_PLAN = enterprise"
  else
    log "WARN: plan=${plan:-?} install=${install_plan:-?} (ambos deben ser enterprise)"
    log "      Tras ./newscript.sh, recarga la página con Ctrl+Shift+R"
  fi
}

apply() {
  prepare_host_initializer
  detect_chatwoot_stack
  log "Stack: ${COMPOSE_PROJECT}"

  write_initializer
  deploy_initializer_to_container "${RAILS_CONTAINER}"
  [[ -n "${SIDEKIQ_CONTAINER:-}" ]] && deploy_initializer_to_container "${SIDEKIQ_CONTAINER}"

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
