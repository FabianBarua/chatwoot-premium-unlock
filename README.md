# Chatwoot Premium Unlock

Activa funciones **Enterprise/premium** en Chatwoot (Docker / Dokploy) **sin tocar el compose**.

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

Debe mostrar: `enterprise`

## Dokploy — no editar compose

El script usa `docker cp` + restart. **No añadas volumes** al compose de Dokploy.

Tras cada **redeploy** de Chatwoot en Dokploy, vuelve a ejecutar:

```bash
cd /home/chatwoot-premium-unlock && ./newscript.sh
```

## Arreglar deploy roto (añadiste un volume antes)

Quita la línea del activador en Dokploy → chatwoot → Compose (deja solo `chatwoot-storage`), redeploy, luego:

```bash
cd /home/chatwoot-premium-unlock
rm -rf custom_configs/zzz_local_premium_unlock.rb
mkdir -p custom_configs
./newscript.sh
```

## Qué hace

- Detecta `chatwoot-rails` y `chatwoot-sidekiq`
- Copia un initializer Ruby al contenedor
- Reinicia rails + sidekiq (~30s downtime)
- Plan `enterprise` + features premium en todas las cuentas
