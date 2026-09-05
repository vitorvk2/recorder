#!/usr/bin/env python3
"""Conta descontinuidades no áudio capturado e diz se elas caem na fronteira
do buffer de IO.

Um clique num múltiplo exato de 512 amostras não é ruído da fonte: é o
aggregate device corrigindo deriva porque o tap e o dispositivo master estão
em taxas diferentes (ex.: tap a 48 kHz sobre EarPods a 44,1 kHz).

    tools/check-clicks.py                     # a gravação mais recente
    tools/check-clicks.py ~/Documents/Recordings/2026-9-5-1403
"""
from __future__ import annotations

import array
import sys
from collections import Counter
from pathlib import Path

SALTO = 0.25          # descontinuidade de amplitude que conta como clique
BLOCO = 512           # frames por ciclo de IO do Core Audio
TAXA = 48_000


def carregar(caf: Path) -> array.array:
    raw = caf.read_bytes()
    i = raw.find(b"data")
    off = i + 16 if i >= 0 else 0
    a = array.array("f")
    a.frombytes(raw[off : off + ((len(raw) - off) // 4) * 4])
    return a


def analisar(pasta: Path) -> int:
    caf = pasta / "desktop.caf"
    if not caf.is_file():
        print(f"{pasta.name}: sem desktop.caf (já foi limpo pelo import?)")
        return 1

    a = carregar(caf)
    if not a:
        print(f"{pasta.name}: arquivo vazio")
        return 1

    cliques = []
    anterior = a[0]
    for k in range(1, len(a)):
        if abs(a[k] - anterior) > SALTO:
            cliques.append(k)
        anterior = a[k]

    dur = len(a) / TAXA
    print(f"{pasta.name}: {dur:.1f}s, {len(cliques)} cliques ({len(cliques)/dur:.1f}/s)")

    if not cliques:
        print("  limpo")
        return 0

    espacos = [cliques[k + 1] - cliques[k] for k in range(len(cliques) - 1)]
    if espacos:
        alinhados = sum(1 for g in espacos if g % BLOCO == 0)
        pct = 100 * alinhados / len(espacos)
        print(f"  alinhados à fronteira de {BLOCO}: {alinhados}/{len(espacos)} ({pct:.0f}%)")
        for g, n in Counter(espacos).most_common(3):
            print(f"    {g:6d} ({g / TAXA * 1000:6.2f} ms) x{n}")
        if pct > 80:
            print("  => descompasso de taxa entre o tap e o dispositivo de saída")
        else:
            print("  => cliques não alinhados: provavelmente vêm da própria fonte")
    return 0


def main() -> int:
    if len(sys.argv) > 1:
        alvo = Path(sys.argv[1]).expanduser()
    else:
        raiz = Path.home() / "Documents" / "Recordings"
        pastas = sorted(
            (d for d in raiz.iterdir() if d.is_dir()),
            key=lambda d: d.stat().st_mtime,
            reverse=True,
        )
        if not pastas:
            print(f"nenhuma gravação em {raiz}")
            return 1
        alvo = pastas[0]
    return analisar(alvo)


if __name__ == "__main__":
    sys.exit(main())
