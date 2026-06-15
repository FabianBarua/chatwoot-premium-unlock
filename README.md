# Chatwoot Premium Unlock

Activa funciones **Enterprise/premium** en Chatwoot (Docker / Dokploy) sin tocar el código fuente.

## Instalación

```bash
cd /home
git clone https://github.com/FabianBarua/chatwoot-premium-unlock.git
cd chatwoot-premium-unlock
chmod +x newscript.sh
sed -i 's/\r$//' newscript.sh
```

## Uso

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

→ `enterprise`

## Persistir en Dokploy (solo 1 línea)

**Orden importante:**

1. `./newscript.sh` — crea el archivo (borra carpeta si Docker la creó antes)
2. En Dokploy → chatwoot → Compose, en `x-base-config` → `volumes`, **añade solo**:

```yaml
    - /home/chatwoot-premium-unlock/custom_configs/zzz_local_premium_unlock.rb:/app/config/initializers/zzz_local_premium_unlock.rb:ro
```

3. Redeploy en Dokploy

No cambies commands ni el resto del compose. Ver `dokploy-volume.txt`.

## Error "not a directory" al deploy

El volume se añadió **antes** de que existiera el archivo. Docker creó una **carpeta**.

```bash
cd /home/chatwoot-premium-unlock
# Quita el volume del compose en Dokploy y redeploy (o para rails/sidekiq)
./newscript.sh              # borra carpeta y crea el .rb
file custom_configs/zzz_local_premium_unlock.rb   # debe ser archivo, no directory
# Añade el volume otra vez y redeploy
```

## Notas

- El script elimina `custom_configs/zzz_local_premium_unlock.rb` si es carpeta
- Sin el volume en Dokploy, el premium se pierde en el próximo redeploy
- `docker-compose.yaml` del repo es referencia **sin** el volume (lo añades tú en Dokploy)
