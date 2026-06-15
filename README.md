# Chatwoot Premium Unlock

Activa funciones **Enterprise/premium** en Chatwoot self-hosted (Docker / Dokploy) sin modificar el código fuente.

## Requisitos

- VPS con Docker
- Chatwoot en ejecución (`chatwoot-rails` + `chatwoot-sidekiq`)
- Acceso a `docker` (root ok)

## Instalación

```bash
cd /home
git clone https://github.com/FabianBarua/chatwoot-premium-unlock.git
cd chatwoot-premium-unlock
chmod +x newscript.sh
sed -i 's/\r$//' newscript.sh   # si clonaste desde Windows
```

## Uso rápido

```bash
./newscript.sh --status   # ver stack (no cambia nada)
./newscript.sh            # activar premium
./newscript.sh --remove   # quitar
```

Verificar:

```bash
docker exec $(docker ps -qf label=com.docker.compose.service=chatwoot-rails) \
  bundle exec rails runner "puts ChatwootHub.pricing_plan" 2>/dev/null | tail -1
```

Debe mostrar: `enterprise`

## Persistir en Dokploy

1. Ejecuta `./newscript.sh` en el servidor (crea el `.rb` dentro de `custom_configs/`).
2. Pega el `docker-compose.yaml` de este repo en **Dokploy → chatwoot → Compose**.
3. Redeploy.

Monta la **carpeta** `custom_configs/` (no el archivo suelto). Al arrancar, rails/sidekiq copian el initializer al contenedor.

## Si falla el deploy: "not a directory"

El volume apuntaba a un **archivo** que Docker convirtió en **carpeta**. Arreglo:

```bash
cd /home/chatwoot-premium-unlock
docker stop serverxplus-chatwoot-zttbp0-chatwoot-rails-1 \
  serverxplus-chatwoot-zttbp0-chatwoot-sidekiq-1 2>/dev/null || true
rm -rf custom_configs/zzz_local_premium_unlock.rb
mkdir -p custom_configs
./newscript.sh
file custom_configs/zzz_local_premium_unlock.rb   # debe decir "ASCII" o "Ruby", NO "directory"
git pull   # compose con mount de carpeta
# Actualiza compose en Dokploy y redeploy
```

## Qué hace

- Detecta `chatwoot-rails` y `chatwoot-sidekiq` por labels Docker Compose
- Inyecta un initializer Ruby
- Reinicia rails + sidekiq (~30s downtime)
- Plan `enterprise` + feature flags premium en todas las cuentas

## Notas

- Solo afecta el stack Chatwoot detectado
- Orden: `./newscript.sh` **antes** del redeploy con compose nuevo
- No modifica la imagen oficial `chatwoot/chatwoot`
