#!/usr/bin/env bash
# Fix Frappe Docker asset mismatch caused by bench migrate overwriting assets.json.
# See: https://github.com/frappe/frappe_docker/issues/1883
#
# The image ships with pre-built assets AND a matching assets.json. `bench migrate`
# (and `bench build` at runtime) overwrite assets.json with runtime-compiled hashes
# that only exist in one container's writable layer — causing 404s on frontend.
# Fix: restore assets.json from the image, which matches what's actually on disk.

set -euo pipefail

BACKEND=$(docker ps --format '{{.Names}}' | grep '\-backend\-' | head -1)
FRONTEND=$(docker ps --format '{{.Names}}' | grep '\-frontend\-' | head -1)
REDIS_CACHE=$(docker ps --format '{{.Names}}' | grep '\-redis-cache\-' | head -1)

if [[ -z "$BACKEND" || -z "$FRONTEND" || -z "$REDIS_CACHE" ]]; then
  echo "ERROR: Could not detect running containers. Is the stack up?" >&2
  exit 1
fi

# Detect the sites volume name from the backend container's mounts
SITES_VOLUME=$(docker inspect "$BACKEND" \
  --format '{{range .Mounts}}{{if eq .Destination "/home/frappe/frappe-bench/sites"}}{{.Name}}{{end}}{{end}}')

if [[ -z "$SITES_VOLUME" ]]; then
  echo "ERROR: Could not detect sites volume from backend container." >&2
  exit 1
fi

# Use the same image the backend container is running
IMAGE=$(docker inspect "$BACKEND" --format '{{.Config.Image}}')

echo "Backend container : $BACKEND"
echo "Frontend container: $FRONTEND"
echo "Sites volume      : $SITES_VOLUME"
echo "Image             : $IMAGE"
echo ""

echo "-> Restoring assets.json from image into shared volume..."
# Mount the volume read-write and copy the image's canonical assets.json into it.
# The image has assets.json under /home/frappe/frappe-bench/sites/assets/ that matches
# the image's pre-built files in apps/*/public/dist/. Both containers use the same image,
# so those files exist in both — meaning the restored assets.json will match on both sides.
docker run --rm \
  -v "${SITES_VOLUME}:/mnt/sites" \
  --entrypoint sh \
  "$IMAGE" \
  -c 'cp -f /tmp/image-assets/assets.json      /mnt/sites/assets/assets.json 2>/dev/null || true;
      cp -f /tmp/image-assets/assets-rtl.json  /mnt/sites/assets/assets-rtl.json 2>/dev/null || true;
      # Image content is at the original path - the VOLUME mount hides it, so we stage first
      true' || true

# Previous block tries a staged copy; since VOLUME hides the image path, do it in one shot
# by running a temp container without mounting the volume at /sites:
docker run --rm \
  -v "${SITES_VOLUME}:/mnt/sites" \
  --entrypoint sh \
  "$IMAGE" \
  -c '
    set -e
    # Read from the image layer at a path NOT covered by the VOLUME
    IMG_ASSETS=/home/frappe/frappe-bench/sites/assets
    if [ -f "$IMG_ASSETS/assets.json" ]; then
      cp -f "$IMG_ASSETS/assets.json"     /mnt/sites/assets/assets.json
      echo "  assets.json restored"
    else
      echo "  WARN: image has no assets.json at $IMG_ASSETS"
    fi
    if [ -f "$IMG_ASSETS/assets-rtl.json" ]; then
      cp -f "$IMG_ASSETS/assets-rtl.json" /mnt/sites/assets/assets-rtl.json
      echo "  assets-rtl.json restored"
    fi
  '

echo ""
echo "-> Flushing Redis cache..."
docker exec "$REDIS_CACHE" redis-cli FLUSHALL >/dev/null
echo "  redis flushed"

echo ""
echo "-> Restarting backend and frontend..."
docker restart "$BACKEND" "$FRONTEND" >/dev/null
echo "  restarted"

echo ""
echo "-> Waiting for backend to come up..."
sleep 8

echo ""
echo "=== Verification ==="
# Only two things need to match:
#   1. assets.json (what backend HTML references)
#   2. frontend's apps/ (what nginx actually serves)
# Backend's apps/ is irrelevant - gunicorn doesn't serve static files.
FRONTEND_FILE=$(docker exec "$FRONTEND" ls /home/frappe/frappe-bench/apps/frappe/frappe/public/dist/css/ 2>/dev/null | grep '^desk.bundle.*css$' | head -1)
ASSETS_JSON_REF=$(docker exec "$FRONTEND" grep -oE 'desk\.bundle\.[A-Z0-9]+\.css' /home/frappe/frappe-bench/sites/assets/assets.json 2>/dev/null | head -1)

echo "assets.json references       : $ASSETS_JSON_REF"
echo "Frontend apps/...desk.bundle : $FRONTEND_FILE   <- what nginx serves"

if [[ -n "$ASSETS_JSON_REF" && "$ASSETS_JSON_REF" = "$FRONTEND_FILE" ]]; then
  echo ""
  echo "OK - assets.json matches frontend disk. Hard refresh browser (Ctrl+Shift+R)."
else
  echo ""
  echo "Still mismatched. Check that the image actually contains assets.json:"
  echo "  docker run --rm --entrypoint ls $IMAGE /home/frappe/frappe-bench/sites/assets/"
fi
