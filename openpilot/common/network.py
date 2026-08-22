import os

# set in launch_env.sh; when "1", the device runs fully offline:
# no Wi-Fi (scan/connect/tether), no API requests, no uploads, no update fetches
NETWORK_DISABLED = os.getenv("DISABLE_NETWORK") == "1"
