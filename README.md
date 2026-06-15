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

1. Ejecuta `./newscript.sh` (genera `custom_configs/zzz_local_premium_unlock.rb`)
2. En **Dokploy → chatwoot → Compose**, añade en `x-base-config` → `volumes`:

```yaml
- /home/chatwoot-premium-unlock/custom_configs/zzz_local_premium_unlock.rb:/app/config/initializers/zzz_local_premium_unlock.rb:ro
```

(Ajusta la ruta si clonaste en otro sitio.)

3. **Primero** ejecuta `./newscript.sh` (crea el archivo en el host).
4. **Después** redeploy en Dokploy.

> Si montas el volume antes de que exista el archivo, Docker crea una **carpeta** con ese nombre. El script lo corrige solo; o manualmente: `rm -rf custom_configs/zzz_local_premium_unlock.rb`

El `composefile` de este repo ya trae esa línea.

## Qué hace

- Detecta `chatwoot-rails` y `chatwoot-sidekiq` por labels Docker Compose
- Inyecta un initializer Ruby
- Reinicia rails + sidekiq (~30s downtime)
- Plan `enterprise` + feature flags premium en todas las cuentas

## Notas

- Solo afecta el stack Chatwoot detectado
- Sin el volume en Dokploy, se pierde en el próximo redeploy
- No modifica la imagen oficial `chatwoot/chatwoot`
