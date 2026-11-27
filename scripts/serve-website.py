# Local preview for website/: serves /support as support.html, like Vercel's cleanUrls.
# Usage: python3 scripts/serve-website.py website [port]
import http.server, os, sys

root = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 4173

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=root, **kw)

    def translate_path(self, path):
        p = super().translate_path(path)
        if not os.path.exists(p) and os.path.exists(p + ".html"):
            return p + ".html"
        return p

    def guess_type(self, path):
        return "text/plain; charset=utf-8" if path.endswith(".sh") else super().guess_type(path)

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
