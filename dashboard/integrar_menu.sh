#!/usr/bin/env bash
# Acrescenta apenas a opção 13; mantém 0-12 e opção 12 intactos.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MENU="$ROOT/menu.sh"
[[ -f "$MENU" ]] || { echo 'ERRO: coloca a pasta dashboard/ ao lado de menu.sh.' >&2; exit 1; }
python3 - "$MENU" <<'PY'
from pathlib import Path
import subprocess,sys
p=Path(sys.argv[1]); text=p.read_text(encoding='utf-8')
if '13 - Instalar Dashboard' in text and 'script="dashboard/install.sh"' in text:
    print('OK: a opção 13 já está integrada.'); sys.exit(0)
anchor1='echo " 0 - Sair"'; anchor2='12) \tscript="todos" ;;'
if text.count(anchor1)!=1 or text.count(anchor2)!=1:
    raise SystemExit('ERRO: menu.sh diferente do esperado. Nenhum ficheiro foi alterado.')
text=text.replace(anchor1,'echo "13 - Instalar Dashboard (opcional)"\n\t'+anchor1)
text=text.replace(anchor2,anchor2+'\n\t\t13) \tscript="dashboard/install.sh" ;;')
backup=p.with_suffix('.sh.bak-dashboard'); backup.write_bytes(p.read_bytes())
tmp=p.with_suffix('.sh.tmp-dashboard'); tmp.write_text(text,encoding='utf-8')
tmp.chmod(p.stat().st_mode)
if subprocess.run(['bash','-n',str(tmp)]).returncode:
    tmp.unlink(missing_ok=True)
    raise SystemExit('ERRO: a alteração de menu falhou a validação; o original está preservado.')
tmp.replace(p)
print('OK: adicionada opção 13 ao menu; opções 1 a 12 preservadas.')
print(f'Backup: {backup}')
PY
