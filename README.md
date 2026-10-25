# Model Share

**Author:** MisterCreators Custom MOCs

A tool script that copies a model, a single file or a whole folder from one EdgeTX radio to another. Both radios run the tool: one sends, one receives. A received model arrives as a new model and is ready to use on the second radio.

Two ways to connect the radios:

| Connection | Cable | Direction | Speed |
|------------|-------|-----------|-------|
| **Trainer cable** (default) | Plain 3.5 mm audio cable between the trainer jacks | One way: the Slave radio sends, the Master radio receives | About 3 minutes for a typical model |
| **Serial** | Crossed serial cable between two ports set to LUA | Both ways | A few seconds for a model |

> **Status:** the trainer cable connection is tested on a Flysky PL18EV and a Jumper T18 Pro. The serial connection is tested only in a simulation so far, not yet on real radios.

## Installation

1. Copy `SCRIPTS/TOOLS/ModelShare.lua` to `/SCRIPTS/TOOLS/` on the SD card of **both** radios. Always use the same version on both radios.
2. Start **SYS → Tools → Model Share**.

Model Share needs a radio with a colour screen. EdgeTX 2.10 or newer is recommended.

## Trainer cable

### One-time setup

**Sending radio:** create a separate, empty model for sharing, for example "Share TX". In that model:
1. Set **Internal RF** and **External RF** to **Off**.
2. Set **Model Setup → Trainer → Mode** to **Slave/Jack**. Leave the other trainer settings at their defaults.
3. The first time you send from this model, Model Share asks for its mixes. Tap **Add mixes**. This adds mixes CH1–CH8 = GV1–GV8 that replace those channels. That's why this has to be a separate model.

**Receiving radio:** create a model for receiving, for example "Share RX", with **Model Setup → Trainer → Mode** set to **Master/Jack**. Internal RF Off is recommended here too.

To send in the other direction, select the other share model on each radio. With "Share TX" and "Share RX" on both radios, you only switch models, never settings.

### Sending and receiving

1. Connect the trainer jacks of both radios with the 3.5 mm cable.
2. **Receiving radio:** select the Master model, open Model Share, tap **Receive**.
3. **Sending radio:** select the Slave model, open Model Share, tap **Send model** or **Send files / folder** and choose what to send.
4. The sender repeats everything in rounds. The receiver collects the pieces, checks them, and shows **"Receive complete"** when everything has arrived.
5. Stop the sender with **X**.
6. **Restart the receiving radio** to see a received model in the model list.

### Speed

Set the speed in the main menu, or change it with the **Speed** button while sending. It only matters on the sending radio.

| Speed | Each piece of data is held for |
|-------|-------------------------------|
| Safe | 200 ms |
| Normal | 120 ms |
| Fast | 80 ms |
| Turbo | 70 ms |

The fastest speed that works depends on the **receiving** radio: each piece must be held longer than the radio's longest gap between two reads, plus up to one PPM frame (~22 ms). The **connection test** shows that gap. If pieces are lost, choose a slower speed.

Measured with the PL18EV sending and the T18 Pro receiving (the T18 reads every 50–60 ms): Fast and Turbo both work, and a model takes about 3 minutes at Turbo.

Files larger than 64 KB are skipped, because they would take too long.

### Connection test

Tap **Connection test**, then **Send test signal** on the sending radio and **Receive test signal** on the receiving one. The receiver shows:
- how often it reads the trainer inputs ("Script reads every … ms")
- how many test pieces were missed or wrong
- the largest value error
- a verdict: **Link OK at this speed**, **Symbols are missed: try a slower speed**, or **Values arrive too imprecise**

### Safety

- Model Share **refuses to send while an RF module is on**, and offers no mixes then. The data would otherwise go out over the air as wild stick movements.
- Never use the sending model for flying. Its channels are driven by the transfer.

## Serial

Both radios need a serial port set to **LUA** (**SYS → Hardware → Serial ports**), with the same baud rate on both. The default 115200 works. Connect them with a crossed cable:

| Radio A | Radio B |
|---------|---------|
| TX      | RX      |
| RX      | TX      |
| GND     | GND     |

**Do not connect the power pins.**

Notes:
- **USB-VCP doesn't work radio to radio.** Both radios are USB devices, and a crossed USB cable doesn't work either.
- The **3.5 mm jacks are trainer ports, not serial ports.**

Switch the main menu entry **Connection** to **Serial**. Data flows both ways, and every packet is confirmed by the other radio and sent again if needed.

## Main menu

| Entry | What it does |
|-------|--------------|
| **Send model** | Lists your models by name. Tap one to send it. Its model image from `/IMAGES/` is sent along with it. |
| **Send files / folder** | Browse the SD card. Tap a file to send it, or tap **[ Send this whole folder ]** to send the folder with all its subfolders. |
| **Receive** | Waits for the other radio and saves everything it receives. |
| **Connection test** | Trainer cable: measures timing and errors (see above). Serial: sends 20 test packets and shows how many came back and the response time. |
| **Overwrite existing files** | Receiving radio: if **Yes**, received files replace files with the same name. If **No**, those files are skipped. Models are always saved as new models. |
| **Connection** | Switches between **Trainer cable** and **Serial**. |
| **Speed** | Trainer cable, sending radio: see [Speed](#speed). |

With the trainer cable, Model Share reads the trainer mode of the active model and grays out what this radio can't do:

| Active model | Available |
|--------------|-----------|
| Slave/Jack | Send model, Send files / folder, Connection test, Speed |
| Master/Jack | Receive, Connection test, Overwrite existing files |
| Trainer Off | only **Connection** |

The bottom line of the menu shows the detected mode. After changing the trainer mode, close and reopen Model Share; the radio saves the change a moment later.

## Status indicators

The title bar shows the connection state on every screen.

| Connection | Display |
|------------|---------|
| Trainer cable, sending radio | **Transmitter**. Green while sending. |
| Trainer cable, receiving radio | 🔴 **No signal**: nothing arrives. 🟠 **Signal**: values arrive but no valid data yet. 🟢 **Data**: data arrives correctly. |
| Serial | 🟢 **Online**: the other radio has Model Share open and the cable works. 🔴 **Offline**: nothing arrived for 1.5 seconds. 🟠 **Version!**: the other radio runs a different version of Model Share. |

More status information:
- **Receive screen (trainer cable):** files complete, packets OK and bad, link quality, actual speed and estimated time left. It also shows the raw values TR1–TR8, which help with troubleshooting.
- **Send screen (trainer cable):** current round and file, speed, and the actual step time next to the set one.
- **Serial:** the main menu shows which serial port is set to LUA. It shows **"Other radio wants to send: tap Receive"** when the other radio is waiting.

## What gets saved where

- A received model is always saved as a **new** model (the next free `modelXX.yml`). It never replaces one of your models.
- Files and folders keep their path. For example, `/SOUNDS/en/hello.wav` arrives as `/SOUNDS/en/hello.wav`. Missing folders are created.
- `/RADIO/` (radio settings and stick calibration) and the model index files (`models.yml`, `labels.yml`) are never sent and never overwritten.
- Every packet has a checksum, and every file is checked again when it is complete. A file that arrives damaged is deleted and received again.

## Notes

- When the two radios are different types, switches and pots may be named differently. Check the switches and mixes of a received model before flying.
- With the trainer cable, Model Share changes GV1–GV8 of the sending model many times per second. The radio may save that model to the SD card more often during a transfer.
- **Always check a received model before flying, with the props off.**
