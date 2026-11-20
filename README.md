KOReader can automatically turn off Wi-Fi when it detects little network activity. The option, “Disable Wi-Fi connection when inactive”, must be enabled in the settings.

When Wi-Fi connects, KOReader checks the number of packets sent by the network interface:
- The first check takes place after 5 minutes. If no more than 12 packets have been sent, KOReader treats them as background traffic and turns Wi-Fi off.
- If there has been more activity, Wi-Fi stays on. The next check takes place after **10 minutes**, and subsequent intervals increase to **15, 20, 25 and 30 minutes**.
- If automatic standby is configured, these intervals are halved. The first check takes place after 2 minutes and 30 seconds, and the maximum interval is 15 minutes.
These times are defined in [networklistener.lua (line 85)]

The 2-reader-wifi-idle patch adds a selectable delay for automatic Wi-Fi shutdown while reading. You can choose 30 seconds, 1 minute, 1 minute and 30 seconds, or 2 minutes. 
The default is 1 minute.

The timer starts when you close the last recognized online service window. 
If you open another recognized online window, the timer is cancelled and starts again when that window closes.

This can be useful if you forget to turn Wi-Fi off after using KOReader’s translation services, such as Google Translate, 
or internet-connected plugins such as KOAssistant and X-Ray.

The patch has only been tested on Kindle. Its compatibility with Kobo and other devices has not been verified.

<img width="616" height="538" alt="a" src="https://github.com/user-attachments/assets/c3f165fc-6658-4ad9-883b-4bae891f3b5c" />
<img width="494" height="659" alt="1" src="https://github.com/user-attachments/assets/31de0442-af43-418f-ac4c-958c3e6002c6" />
<img width="494" height="659" alt="2" src="https://github.com/user-attachments/assets/4a98e895-4a7e-4515-a830-caf6ac19183c" /> 
