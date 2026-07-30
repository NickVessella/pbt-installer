# Step 4 Gate Scripts

## Stylesheet sanity check

Run after confirming a 2xx response from the dev server. Verifies that every CSS file referenced in the page HTML actually resolves. A page can return 200 OK with completely broken styles — this catches the "CSS file 404" class of bugs that a status-code-only check misses.

```bash
curl -s http://localhost:<port> \
  | grep -oP '(?<=href=")[^"]*\.css[^"]*' \
  | while read href; do
      url=$(echo "$href" | grep -q '^http' && echo "$href" || echo "http://localhost:<port>$href")
      status=$(curl -s -o /dev/null -w '%{http_code}' "$url")
      [ "$status" != "200" ] && echo "FAIL: $href returned $status" && exit 1
    done
```

If any stylesheet returns non-200, the runtime gate fails.
