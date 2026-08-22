# Build and install openpilot on a comma four

How to compile openpilot and deploy your own version onto a comma four. The device compiles openpilot itself; your job is just to get your code somewhere it can fetch from.

## Option A: install via installer URL (recommended)

1. Fork openpilot on GitHub, push your changes (or use any existing branch).
2. On the comma four: **Settings** → uninstall openpilot.
3. Reinstall using your custom URL:

   ```
   installer.comma.ai/<your-github-username>/<branch>
   ```

4. The device clones the branch and compiles it on first boot (runs `scons` internally).

### Prebuilt branches

| URL                        | Branch                  | Description                                                                    |
|----------------------------|-------------------------|--------------------------------------------------------------------------------|
| `openpilot.comma.ai`       | `release-mici`          | Release branch                                                                 |
| `openpilot-test.comma.ai`  | `release-mici-staging`  | Staging for upcoming releases                                                  |
| `openpilot-nightly.comma.ai` | `nightly`             | Bleeding edge development branch, do not expect stability                      |

## Option B: build directly over SSH

1. Enable SSH in the device settings and enter your GitHub username there.
2. Connect to the device (default password `comma`):

   ```bash
   ssh comma@<device-ip>
   ```

3. Clone and build:

   ```bash
   git clone https://github.com/<you>/openpilot.git /data/openpilot
   cd /data/openpilot && source .venv/bin/activate && scons -j4
   ```

## Building locally on your computer

For development and simulation only — this does not produce an installer image:

```bash
bash <(curl -fsSL openpilot.comma.ai)   # one-time setup of dependencies
cd openpilot && source .venv/bin/activate
scons                                    # also builds panda firmware
```

## Notes on panda firmware

Panda firmware is flashed automatically every time openpilot starts. To flash it manually over USB:

```bash
cd panda/board
./flash.py            # or ./recover.py if the panda is unresponsive
```
