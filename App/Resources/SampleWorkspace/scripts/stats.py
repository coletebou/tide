#!/usr/bin/env python3
"""Print word statistics for the Markdown files in a folder."""
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


@dataclass
class FileStats:
    path: Path
    words: int
    headings: int

    @property
    def density(self) -> float:
        return self.headings / max(self.words, 1)


def collect(folder: Path) -> list[FileStats]:
    stats = []
    for path in sorted(folder.rglob("*.md")):
        text = path.read_text(encoding="utf-8")
        words = len(text.split())
        headings = sum(1 for line in text.splitlines() if line.startswith("#"))
        stats.append(FileStats(path, words, headings))
    return stats


if __name__ == "__main__":
    counts = Counter()
    for item in collect(Path(".")):
        counts[item.path.suffix] += item.words
        print(f"{item.path}: {item.words} words, {item.headings} headings")
    print("Total:", sum(counts.values()))
