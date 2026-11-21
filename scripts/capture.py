"""Capture Confly's real Neovim UI grid as PNGs (not design mockups).

Development-only dependencies: pip install pynvim pillow
Usage: python scripts/capture.py [--font PATH]
"""

import argparse
import getpass
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile

import pynvim
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
COLS, ROWS = 150, 37


def git(repo, *args, check=True):
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=check, capture_output=True
    )


def fixture(repo):
    git(repo, "init", "-b", "main")
    git(repo, "config", "user.name", "Confly Demo")
    git(repo, "config", "user.email", "demo@confly.local")
    git(repo, "config", "core.autocrlf", "false")
    git(repo, "config", "commit.gpgsign", "false")
    (repo / "src").mkdir()
    source = [
        "-- Application configuration",
        "local M = {}",
        "",
        "M.server = {",
        '  host = "localhost",',
        "  port = 3000,",
        "}",
        "",
        "M.cache = {",
        "  enabled = true,",
        "  ttl = 60,",
        "}",
        "",
        "function M.start()",
        '  local message = "Starting server"',
        "  print(message)",
        "  return M.server",
        "end",
        "",
        "return M",
    ]
    base = "\n".join(source) + "\n"
    (repo / "src" / "config.lua").write_text(base, encoding="utf-8")
    (repo / "src" / "routes.lua").write_text('return { home = "/" }\n', encoding="utf-8")
    (repo / "README.md").write_text("# Application\n", encoding="utf-8")
    git(repo, "add", ".")
    git(repo, "commit", "-m", "Base application")
    git(repo, "checkout", "-b", "feature/server")
    (repo / "src" / "config.lua").write_text(
        base.replace("port = 3000", "port = 8080").replace(
            '"Starting server"', '"Server is ready"'
        ),
        encoding="utf-8",
    )
    (repo / "src" / "routes.lua").write_text('return { home = "/welcome" }\n', encoding="utf-8")
    (repo / "README.md").write_text("# Application server\n", encoding="utf-8")
    git(repo, "commit", "-am", "Incoming server defaults")
    git(repo, "checkout", "main")
    (repo / "src" / "config.lua").write_text(
        base.replace("port = 3000", "port = 4000").replace(
            '"Starting server"', '"Booting application"'
        ),
        encoding="utf-8",
    )
    (repo / "src" / "routes.lua").write_text('return { home = "/dashboard" }\n', encoding="utf-8")
    (repo / "README.md").write_text("# Application dashboard\n", encoding="utf-8")
    git(repo, "commit", "-am", "Current application defaults")
    result = git(repo, "merge", "feature/server", check=False)
    assert result.returncode == 1, result.stderr


class Grid:
    def __init__(self):
        self.cells = [[(" ", 0) for _ in range(COLS)] for _ in range(ROWS)]
        self.attrs = {}
        self.foreground = 0xC0CAF5
        self.background = 0x1A1B26
        self.cursor = None

    def redraw(self, events):
        for event in events:
            name, calls = event[0], event[1:]
            for args in calls:
                if name == "default_colors_set":
                    if args[0] >= 0:
                        self.foreground = args[0]
                    if args[1] >= 0:
                        self.background = args[1]
                elif name == "hl_attr_define":
                    self.attrs[args[0]] = args[1]
                elif name == "grid_resize" and args[0] == 1:
                    self.cells = [[(" ", 0) for _ in range(args[1])] for _ in range(args[2])]
                elif name == "grid_clear" and args[0] == 1:
                    self.cells = [[(" ", 0) for _ in row] for row in self.cells]
                elif name == "grid_line" and args[0] == 1:
                    _, row, col, cells, *_ = args
                    attr = 0
                    for cell in cells:
                        text = cell[0]
                        if len(cell) > 1:
                            attr = cell[1]
                        for _ in range(cell[2] if len(cell) > 2 else 1):
                            self.cells[row][col] = (text, attr)
                            col += 1
                elif name == "grid_scroll" and args[0] == 1:
                    _, top, bottom, left, right, rows, cols = args
                    old = [row[:] for row in self.cells]
                    for y in range(top, bottom):
                        for x in range(left, right):
                            yy, xx = y + rows, x + cols
                            self.cells[y][x] = (
                                old[yy][xx]
                                if top <= yy < bottom and left <= xx < right
                                else (" ", 0)
                            )
                elif name == "grid_cursor_goto" and args[0] == 1:
                    self.cursor = (args[2], args[1])

    def validate_anonymous(self, private_values):
        """Check the actual rendered text, including headers and status lines."""
        text = "\n".join("".join(cell[0] for cell in row) for row in self.cells)
        if re.search(r"(?i)(?:(?<!\w)[a-z]:[/\\]|/(?:Users|home)/|AppData[/\\]|confly-demo-)", text):
            raise ValueError("Capture contains a machine-specific path; refusing to save.")
        for value in private_values:
            if value and len(value) >= 3 and re.search(
                r"(?<!\w)" + re.escape(value) + r"(?!\w)", text, re.IGNORECASE
            ):
                raise ValueError("Capture contains local identifying information; refusing to save.")

    def save(self, path, font_path, private_values):
        self.validate_anonymous(private_values)
        font = ImageFont.truetype(str(font_path), 17)
        cell_width = round(font.getlength("M"))
        cell_height = 25
        padding, title_height = 24, 42
        width = len(self.cells[0]) * cell_width + padding * 2
        height = len(self.cells) * cell_height + padding * 2 + title_height
        image = Image.new("RGB", (width, height), "#13141d")
        draw = ImageDraw.Draw(image)
        for i, color in enumerate(("#f7768e", "#e0af68", "#9ece6a")):
            x = padding + i * 22
            draw.ellipse((x, 16, x + 11, 27), fill=color)
        draw.text((padding + 86, 10), "confly  /  Neovim", font=font, fill="#8994b0")

        def color(value):
            return f"#{value:06x}"

        for row, cells in enumerate(self.cells):
            for col, (text, attr_id) in enumerate(cells):
                attr = self.attrs.get(attr_id, {})
                fg = attr.get("foreground", self.foreground)
                bg = attr.get("background", self.background)
                if attr.get("reverse"):
                    fg, bg = bg, fg
                x, y = padding + col * cell_width, title_height + padding + row * cell_height
                draw.rectangle((x, y, x + cell_width - 1, y + cell_height - 1), fill=color(bg))
                if text:
                    draw.text((x, y + 1), text, font=font, fill=color(fg))
        if self.cursor:
            x = padding + self.cursor[0] * cell_width
            y = title_height + padding + self.cursor[1] * cell_height
            draw.rectangle((x, y, x + cell_width - 1, y + cell_height - 1), outline="#82aaff")
        path.parent.mkdir(parents=True, exist_ok=True)
        image.save(path)
        print(f"Captured {path.relative_to(ROOT)} ({width}x{height})")


def capture(nvim, grid, path, font, private_values):
    # A notification barrier drains Neovim's redraw events after the command.
    channel = nvim.channel_id
    nvim.exec_lua(
        "local channel = ...; vim.cmd('redraw!'); "
        "vim.defer_fn(function() vim.rpcnotify(channel, 'capture_done') end, 100)",
        channel,
    )

    def notification(name, args):
        if name == "redraw":
            grid.redraw(args)
        elif name == "capture_done":
            nvim.stop_loop()

    nvim.run_loop(None, notification)
    grid.save(path, font, private_values)


def wait(nvim):
    result = nvim.exec_lua(
        "local c = require('confly'); "
        "assert(vim.wait(20000, function() return not c.status().busy end, 10)); "
        "return c.status().error"
    )
    if result:
        raise RuntimeError(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", type=Path)
    args = parser.parse_args()
    windows_dir = os.environ.get("WINDIR")
    candidates = [
        args.font,
        Path(windows_dir) / "Fonts" / "CascadiaMono.ttf" if windows_dir else None,
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"),
        Path("/System/Library/Fonts/Menlo.ttc"),
    ]
    font = next((p for p in candidates if p and p.exists()), None)
    if not font:
        raise SystemExit("Supply --font with a monospace TTF file.")
    with tempfile.TemporaryDirectory(prefix="confly-demo-") as temporary:
        repo = Path(temporary) / "application"
        repo.mkdir()
        fixture(repo)
        private_values = {
            getpass.getuser(), socket.gethostname(), Path.home().name,
            str(Path.home()), str(ROOT), str(repo),
            Path.home().as_posix(), ROOT.as_posix(), repo.as_posix(),
        }
        nvim = pynvim.attach("child", argv=[shutil.which("nvim"), "--embed", "-u", "NONE", "-n"])
        try:
            nvim.ui_attach(COLS, ROWS, rgb=True, ext_linegrid=True)
            grid = Grid()
            nvim.exec_lua(
                """
                local root, repo = ...
                vim.opt.runtimepath:prepend(root)
                vim.cmd.cd(vim.fn.fnameescape(repo))
                vim.g.mapleader = ' '
                vim.o.termguicolors = true
                vim.o.showtabline = 0
                vim.o.laststatus = 2
                vim.o.showmode = false
                vim.o.shortmess = 'filnxtToOF'
                vim.o.fillchars = 'eob: ,vert:│'
                vim.cmd('filetype on')
                vim.cmd('syntax on')
                for group, attrs in pairs({
                  Normal = { fg = '#c0caf5', bg = '#1a1b26' },
                  NormalNC = { fg = '#c0caf5', bg = '#1a1b26' },
                  LineNr = { fg = '#565f89' },
                  CursorLine = { bg = '#24283b' },
                  CursorLineNr = { fg = '#82aaff' },
                  WinSeparator = { fg = '#414868', bg = '#1a1b26' },
                  WinBar = { fg = '#82aaff', bg = '#24283b' },
                  WinBarNC = { fg = '#8994b0', bg = '#24283b' },
                  StatusLine = { fg = '#a9b1d6', bg = '#24283b' },
                  StatusLineNC = { fg = '#8994b0', bg = '#24283b' },
                  Comment = { fg = '#737aa2', italic = true },
                  String = { fg = '#9ece6a' },
                  Number = { fg = '#ff9e64' },
                  Statement = { fg = '#bb9af7' },
                  Identifier = { fg = '#7dcfff' },
                  Special = { fg = '#7dcfff' },
                }) do vim.api.nvim_set_hl(0, group, attrs) end
                vim.cmd('runtime plugin/confly.lua')
                require('confly').open()
                """,
                str(ROOT), str(repo),
            )
            wait(nvim)
            nvim.exec_lua(
                "local c = require('confly'); local s = c.status().session; "
                "for _, e in ipairs(s.entries) do if e.path == 'README.md' then c.accept_file(e, 2); break end end"
            )
            wait(nvim)
            capture(nvim, grid, ROOT / "docs/screenshots/file-picker.png", font, private_values)
            nvim.exec_lua(
                "local c = require('confly'); local s = c.status().session; "
                "for _, e in ipairs(s.entries) do if e.path == 'src/config.lua' then c.open_file(e); break end end"
            )
            wait(nvim)
            capture(nvim, grid, ROOT / "docs/screenshots/three-pane.png", font, private_values)
            nvim.exec_lua("require('confly').choose('left')")
            capture(nvim, grid, ROOT / "docs/screenshots/result.png", font, private_values)
        finally:
            try:
                nvim.command("qa!")
            except (EOFError, OSError):
                pass
            nvim.close()


if __name__ == "__main__":
    main()
