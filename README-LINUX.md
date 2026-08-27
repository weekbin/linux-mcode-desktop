# MiniMax Code (Linux)

Linux GUI client built from the Windows NSIS installer via
`@mmx-agent/electron v3.0.67-inside.44`.

## Install

```bash
sudo dpkg -i minimax-code_3.0.67-inside.44_amd64.deb
# If dependency errors:
sudo apt-get install -f -y
```

## Launch

```bash
minimax-code
# or
/opt/MiniMax\ Code/run.sh
```

## Uninstall

```bash
sudo dpkg --purge minimax-code
```

## Notes

- Built for Ubuntu 24.04 (GLIBC 2.39+). Older distros need the
  `libmmmx-shim.so` (preloads `fmod@GLIBC_2.38` for jammy/focal).
- On headless servers: `xvfb-run -a minimax-code` or set `DISPLAY=:99`
  with a running `Xvfb`.
