"""Сборка системной документации Think Faster: SYSTEM.md, SYSTEM.html, SYSTEM.pdf.

    python docs/system/build.py            # всё
    python docs/system/build.py --md-only  # только SYSTEM.md

Части — parts/*.md по порядку имён, разделы сервисов — services/*.md в порядке services.json
(вставляются после parts/03-*). Для HTML нужен пакет `markdown`, для PDF и схем — Edge или Chrome и доступ
к cdn.jsdelivr.net (mermaid): браузер рисует схемы, HTML сохраняется уже с SVG, из него печатается PDF.
"""
import datetime
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
# Chrome первым: headless Edge на Windows может молча ничего не вывести (лаунчер отдаёт управление сразу).
BROWSERS = [
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'google-chrome', 'chromium', 'chromium-browser',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', 'msedge',
]


def git(*args: str) -> str:
    try:
        return subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True,
                              check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return '?'


# ----- Markdown ----------------------------------------------------------------------------------

FENCE = re.compile(r'^(```|~~~)')
HEADING = re.compile(r'^(#{1,6})\s+(.*?)\s*#*\s*$')
REL_LINK = re.compile(r'\[([^\]]+)\]\((?!https?://|mailto:|#)([^)]+)\)')


def lines_outside_code(text: str):
    """(строка, в_коде) для каждой строки."""
    in_code = False
    for line in text.split('\n'):
        if FENCE.match(line.strip()):
            yield line, True
            in_code = not in_code
            continue
        yield line, in_code


def normalize_service(text: str, repo: str, ref: str) -> str:
    """Заголовок сервиса — уровень 2, остальные сдвигаются так же; строка версии убирается;
    относительные ссылки — в текст."""
    text = text.replace('\r\n', '\n')
    levels = [len(m.group(1)) for line, code in lines_outside_code(text) if not code
              for m in [HEADING.match(line)] if m]
    shift = 2 - min(levels)
    out, title_done = [], False
    for line, code in lines_outside_code(text):
        if code:
            out.append(line)
            continue
        if re.match(r'^Версия:\s', line):
            continue
        m = HEADING.match(line)
        if m:
            level = min(6, len(m.group(1)) + shift)
            line = '#' * level + ' ' + m.group(2)
            out.append(line)
            if not title_done:
                out.append('')
                out.append(f'> Источник: репозиторий **{repo}**, `{ref}`. Раздел написан агентом репозитория.')
                title_done = True
            continue
        out.append(REL_LINK.sub(lambda mm: f'{mm.group(1)} (`{mm.group(2)}`)' if mm.group(1) != mm.group(2)
                                else mm.group(1), line))
    return '\n'.join(out).strip() + '\n'


def slugify(value: str, used: dict) -> str:
    """Якорь как у GitHub: нижний регистр, без пунктуации, пробелы → дефисы, повтор → -1, -2."""
    s = value.strip().lower()
    s = re.sub(r'`', '', s)
    s = re.sub(r'[^\w\- ]', '', s, flags=re.UNICODE)
    s = s.replace(' ', '-')
    n = used.get(s, 0)
    used[s] = n + 1
    return s if n == 0 else f'{s}-{n}'


def headings(text: str):
    for line, code in lines_outside_code(text):
        if not code:
            m = HEADING.match(line)
            if m:
                yield len(m.group(1)), m.group(2)


def toc(text: str) -> str:
    used: dict = {}
    rows = ['## Содержание', '']
    for i, (level, title) in enumerate(headings(text)):
        slug = slugify(title, used)
        if i == 0 or title == 'Содержание':      # заголовок документа и само оглавление
            continue
        if level == 1:
            rows.append(f'- [{title}](#{slug})')
        elif level == 2:
            rows.append(f'    - [{title}](#{slug})')
    return '\n'.join(rows) + '\n'


def assemble() -> str:
    services = json.loads((HERE / 'services.json').read_text(encoding='utf-8'))
    date = datetime.date.today().isoformat()
    infra_ref = f"{git('rev-parse', '--abbrev-ref', 'HEAD')}@{git('rev-parse', '--short', 'HEAD')}"
    sources = '\n'.join(f"| Часть III — {Path(s['file']).stem} | {s['repo']} | `{s['ref']}` |" for s in services)

    chunks = []
    for part in sorted((HERE / 'parts').glob('*.md')):
        text = part.read_text(encoding='utf-8').replace('\r\n', '\n')
        text = text.replace('{{DATE}}', date).replace('{{INFRA_REF}}', infra_ref).replace('{{SOURCES}}', sources)
        chunks.append(text.strip() + '\n')
        if part.name.startswith('03-'):
            for s in services:
                raw = (HERE / 'services' / s['file']).read_text(encoding='utf-8')
                chunks.append(normalize_service(raw, s['repo'], s['ref']))
    body = '\n\n'.join(chunks)
    title, _, rest = body.partition('\n')
    first_part = rest.find('\n# ')
    intro, rest = rest[:first_part], rest[first_part:]
    return f'{title}\n{intro.rstrip()}\n\n{toc(body)}\n{rest.lstrip()}'


# ----- HTML / PDF --------------------------------------------------------------------------------

CSS = """
@page { size: A4; margin: 14mm 12mm 16mm 12mm; }
:root { --fg:#1b1f24; --muted:#57606a; --line:#d0d7de; --bg2:#f6f8fa; --accent:#0b57d0; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { font-family: "Segoe UI", "Noto Sans", Arial, sans-serif; color: var(--fg); font-size: 10pt;
       line-height: 1.45; max-width: 1100px; margin: 0 auto; padding: 16px; background: #fff; }
h1 { font-size: 20pt; border-bottom: 2px solid var(--accent); padding-bottom: 4px; margin-top: 28px;
     page-break-before: always; break-before: page; }
h1:first-of-type { page-break-before: avoid; break-before: avoid; font-size: 26pt; }
h2 { font-size: 15pt; border-bottom: 1px solid var(--line); padding-bottom: 3px; margin-top: 22px; }
h3 { font-size: 12.5pt; margin-top: 18px; } h4 { font-size: 11pt; } h5, h6 { font-size: 10pt; }
h1, h2, h3, h4 { page-break-after: avoid; break-after: avoid; }
a { color: var(--accent); text-decoration: none; }
code { font-family: Consolas, "Cascadia Mono", monospace; font-size: 8.8pt; background: var(--bg2);
       padding: 0 3px; border-radius: 3px; word-break: break-word; }
pre { background: var(--bg2); border: 1px solid var(--line); border-radius: 5px; padding: 8px 10px;
      white-space: pre-wrap; word-break: break-word; page-break-inside: avoid; }
pre code { background: none; padding: 0; }
table { border-collapse: collapse; width: 100%; margin: 8px 0; font-size: 8.8pt; page-break-inside: auto; }
tr { page-break-inside: avoid; break-inside: avoid; }
th, td { border: 1px solid var(--line); padding: 3px 6px; vertical-align: top; text-align: left;
         word-break: break-word; }
th { background: var(--bg2); }
blockquote { margin: 8px 0; padding: 4px 12px; border-left: 4px solid var(--line); color: var(--muted); }
.mermaid { text-align: center; background: #fff; border: 1px solid var(--line); border-radius: 5px;
           padding: 8px; margin: 10px 0; page-break-inside: avoid; break-inside: avoid; white-space: normal; }
.mermaid svg { max-width: 100% !important; height: auto; }
.mermaid-error { border-color: #cf222e; color: #cf222e; white-space: pre-wrap; text-align: left; }
.toc ul, .toc ol { margin: 0; }
"""

MERMAID_JS = """
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<script>
  mermaid.initialize({ startOnLoad: false, theme: 'default', securityLevel: 'loose',
                       flowchart: { htmlLabels: false, useMaxWidth: true },
                       sequence: { useMaxWidth: true, actorMargin: 20, width: 110, boxMargin: 6,
                                   messageMargin: 30, wrap: true, messageFontSize: 13, actorFontSize: 13,
                                   noteFontSize: 12 } });
  (async () => {
    const nodes = Array.from(document.querySelectorAll('pre.mermaid'));
    let failed = 0;
    for (let i = 0; i < nodes.length; i++) {
      const el = nodes[i];
      try {
        const { svg } = await mermaid.render('m' + i, el.textContent);
        const div = document.createElement('div'); div.className = 'mermaid'; div.innerHTML = svg;
        el.replaceWith(div);
      } catch (e) {
        failed++;
        el.className = 'mermaid mermaid-error';
        el.textContent = 'Схема не отрисовалась: ' + (e.message || e) + '\\n\\n' + el.textContent;
      }
    }
    document.querySelectorAll('script').forEach(s => s.remove());
    const done = document.createElement('meta'); done.name = 'mermaid-status';
    done.content = 'done ' + nodes.length + ' failed ' + failed; document.head.appendChild(done);
  })();
</script>
"""


LIST_ITEM = re.compile(r'^(\s*)([-*+]|\d+[.)])\s')


def for_python_markdown(text: str) -> str:
    """GitHub-разметку — к виду, который понимает python-markdown: пустая строка перед списком и таблицей
    после абзаца, вложенность списков — 4 пробела, блоки кода с отступом (внутри пунктов) — без отступа."""
    out, prev, fence_indent = [], '', None
    for line in text.split('\n'):
        stripped = line.lstrip()
        if fence_indent is not None:                     # внутри блока кода
            out.append(line[fence_indent:] if line[:fence_indent].strip() == '' else line)
            if FENCE.match(stripped):
                fence_indent = None
            prev = line
            continue
        if FENCE.match(stripped):
            fence_indent = len(line) - len(stripped)
            if prev.strip():
                out.append('')
            out.append(stripped)
            prev = line
            continue
        m = LIST_ITEM.match(line)
        if m:
            indent = len(m.group(1))
            line = ' ' * (4 * -(-indent // 4)) + stripped      # 2, 3, 4 пробела → 4; 5–8 → 8
        starts_block = bool(m and not m.group(1)) or stripped.startswith('|')
        prev_is_text = prev.strip() and not LIST_ITEM.match(prev) and not prev.lstrip().startswith('|') \
            and not prev.startswith(' ')
        if starts_block and prev_is_text:
            out.append('')
        out.append(line)
        prev = line
    return '\n'.join(out)


def to_html(md_text: str) -> str:
    import markdown
    md_text = for_python_markdown(md_text)
    blocks = []

    def keep_mermaid(m):
        blocks.append(m.group(1))
        return f'\n\nMERMAIDBLOCK{len(blocks) - 1}\n\n'

    text = re.sub(r'^```mermaid\n(.*?)\n```', keep_mermaid, md_text, flags=re.S | re.M)
    used: dict = {}
    body = markdown.markdown(text, extensions=['tables', 'fenced_code', 'sane_lists', 'toc'],
                             extension_configs={'toc': {'slugify': lambda v, sep: slugify(v, used)}})
    for i, src in enumerate(blocks):
        body = body.replace(f'<p>MERMAIDBLOCK{i}</p>', f'<pre class="mermaid">{html.escape(src)}</pre>')
    return ('<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">'
            '<title>Think Faster — системная документация</title>'
            f'<style>{CSS}</style></head><body>{body}{MERMAID_JS}</body></html>')


def browser() -> str | None:
    for b in BROWSERS:
        if os.path.isabs(b) and os.path.exists(b):
            return b
        found = shutil.which(b)
        if found:
            return found
    return None


def run_browser(exe: str, *args: str) -> subprocess.CompletedProcess:
    profile = tempfile.mkdtemp(prefix='tfdoc-')
    try:
        return subprocess.run([exe, '--headless=new', '--disable-gpu', '--no-first-run', '--no-sandbox',
                               f'--user-data-dir={profile}', *args], capture_output=True, text=True,
                              encoding='utf-8', errors='replace', timeout=300)
    finally:
        shutil.rmtree(profile, ignore_errors=True)


def main() -> int:
    md_text = assemble()
    (HERE / 'SYSTEM.md').write_text(md_text, encoding='utf-8', newline='\n')
    print(f'SYSTEM.md: {len(md_text.splitlines())} строк')
    if '--md-only' in sys.argv:
        return 0

    exe = browser()
    if not exe:
        print('нет Edge/Chrome — HTML и PDF не собраны')
        return 1
    dynamic = HERE / '_render.html'
    dynamic.write_text(to_html(md_text), encoding='utf-8')
    try:
        dump = run_browser(exe, '--virtual-time-budget=120000', '--run-all-compositor-stages-before-draw',
                           '--dump-dom', dynamic.as_uri())
        dom = dump.stdout
        status = re.search(r'name="mermaid-status" content="([^"]+)"', dom)
        print('схемы:', status.group(1) if status else 'не отрисованы (нет ответа mermaid)')
        if not status:
            return 1
        static = HERE / 'SYSTEM.html'
        static.write_text('<!DOCTYPE html>\n' + dom, encoding='utf-8')
        pdf = HERE / 'SYSTEM.pdf'
        run_browser(exe, '--no-pdf-header-footer', '--print-to-pdf-no-header',
                    f'--print-to-pdf={pdf}', static.as_uri())
        print(f'SYSTEM.pdf: {pdf.stat().st_size // 1024} КБ' if pdf.exists() else 'PDF не создан')
        return 0 if pdf.exists() and 'failed 0' in status.group(1) else 2
    finally:
        dynamic.unlink(missing_ok=True)


if __name__ == '__main__':
    sys.exit(main())
