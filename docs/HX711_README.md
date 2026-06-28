# HX711 Amplifier – Technical Reference

> **Companion document for the ESP32 Digital Scale project.**
> This file explains how the HX711 works, how to wire it, how to communicate
> with it, and how this driver implements each step.

---

## Table of Contents

- [HX711 Amplifier – Technical Reference](#hx711-amplifier--technical-reference)
  - [Table of Contents](#table-of-contents)
  - [What Is the HX711?](#what-is-the-hx711)
  - [Internal Block Diagram](#internal-block-diagram)
  - [Load Cell Fundamentals](#load-cell-fundamentals)
    - [Half-Bridge vs Full-Bridge](#half-bridge-vs-full-bridge)
    - [Combining Four Half-Bridge Cells](#combining-four-half-bridge-cells)
  - [HX711 Pin Description](#hx711-pin-description)
  - [Power Supply Considerations](#power-supply-considerations)
  - [Channel and Gain Selection](#channel-and-gain-selection)
  - [Output Data Rate](#output-data-rate)
  - [Serial Communication Protocol](#serial-communication-protocol)
    - [Timing Diagram](#timing-diagram)
    - [Data Format](#data-format)
    - [Gain-Select Pulse Count](#gain-select-pulse-count)
  - [Power-Down Mode](#power-down-mode)
  - [Noise and Resolution](#noise-and-resolution)
  - [Calibration Mathematics](#calibration-mathematics)
    - [1. Tare Offset](#1-tare-offset)
    - [2. Scale Factor](#2-scale-factor)
    - [Weight Calculation](#weight-calculation)
  - [Driver Implementation Notes](#driver-implementation-notes)
    - [Why IRAM?](#why-iram)
    - [Why `portDISABLE_INTERRUPTS()`?](#why-portdisable_interrupts)
    - [Why `ets_delay_us()` Instead of `vTaskDelay()`?](#why-ets_delay_us-instead-of-vtaskdelay)
    - [Sign Extension](#sign-extension)
  - [Common Mistakes](#common-mistakes)
  - [Datasheet Reference](#datasheet-reference)

---

## What Is the HX711?

The **HX711** is a precision 24-bit analog-to-digital converter (ADC) designed specifically for weigh-scale and industrial control applications that use a Wheatstone bridge sensor (load cell, pressure sensor, etc.).

Key specifications:

| Parameter | Value |
| ----------- | ------- |
| ADC resolution | 24 bits |
| Input channels | 2 (A and B) |
| Channel A gain | 64 or 128 (selectable) |
| Channel B gain | 32 (fixed) |
| Output data rate | 10 Hz (pin RATE = 0) or 80 Hz (pin RATE = 1) |
| Supply voltage | 2.6 V – 5.5 V |
| Current consumption | ≈ 1.5 mA active, < 1 µA power-down |
| Interface | Custom 2-wire serial (PD_SCK + DOUT) |
| Internal oscillator | Yes (no external crystal needed) |
| Temperature range | −40 °C to +85 °C |

---

## Internal Block Diagram

```text
                       ┌────────────────────────────────────┐
                       │             HX711                  │
  E+ ─────────────────►│ REG ─► AVDD                        │
  E- ─────────────────►│              ▼                     │
                       │         Bias / Ref                 │
  A+ ─────────────────►│─┐                                  │
  A- ─────────────────►│─┤► MUX ─► PGA (×64/×128) ─► ADC ─► │ DOUT
                       │ │                         24-bit   │
  B+ ─────────────────►│─┘         (×32 for B)              │
  B- ─────────────────►│                                    │
                       │    Internal oscillator             │
                       │    10 Hz / 80 Hz selector          │◄── RATE
                       │                                    │◄── PD_SCK
  VDD ────────────────►│ Digital supply (DVDD)              │
  GND ────────────────►│ GND                                │
                       └────────────────────────────────────┘
```

The on-chip **programmable gain amplifier (PGA)** amplifies the tiny differential signal from the bridge (typically 0 – 20 mV full scale) before it reaches the ADC. A higher gain improves resolution at the cost of a smaller maximum input range.

---

## Load Cell Fundamentals

A **strain gauge load cell** works by bonding metallic foil resistors to a metal beam. When a force is applied, the beam deflects slightly, stretching some resistors and compressing others. The resistance change is typically very small (< 1%).

### Half-Bridge vs Full-Bridge

A **half-bridge** cell has two active gauges (one in tension, one in compression). Its differential output signal is:

```text
V_out = (V_EXC / 2) × (ΔR / R)
```

A **full Wheatstone bridge** uses four gauges (two in tension, two in compression) and doubles the output signal:

```text
V_out = V_EXC × (ΔR / R)
```

More signal → better resolution and noise immunity.

### Combining Four Half-Bridge Cells

The four 50 kg half-bridge cells used in this project are wired to form a **single full Wheatstone bridge**:

```text
         E+ ──────┬──────────────────┬────── E+
                  │                  │
             Cell 1 (tension)   Cell 2 (tension)
                  │                  │
         A+ ──────┤                  ├────── A+
                  │                  │
             Cell 3 (compression) Cell 4 (compression)
                  │                  │
         A- ──────┴──────────────────┴────── A-
                  │
         E- ──────┘
```

**Practical wiring:**

| HX711 terminal | What to connect |
| ---------------- | ----------------- |
| E+ | Red wires of Cells 1 & 3 (tied together) |
| E− | Black wires of Cells 1 & 3 (tied together) |
| A+ | White wires of Cells 2 & 4 (tied together) |
| A− | Green/Yellow wires of Cells 2 & 4 (tied together) |

With this arrangement the four cells share the mechanical load and their signals add constructively, giving a combined full-scale capacity of **200 kg / 440 lbs** (4 × 50 kg).

> **Important:** The physical placement of the cells in the scale frame matters. Cells 1 and 3 must be on one diagonal of the platform, and Cells 2 and 4 on the other. This ensures tensile and compressive forces cancel correctly.

---

## HX711 Pin Description

| Pin | Name | Function | Description | Notes |
| ----- | ------ | ----------- | ------------- | ---------- |
| 1 | VSUP | Power | Regulator supply: 2.7 ~ 5.5V | Main supply voltage (5V) |
| 2 | BASE | Analog Output | Regulator control output | NC when not used |
| 3 | AVDD | Power | Analog supply: 2.6 ~ 5.5V | Power to load cells |
| 4 | VFB | Analog Input | Regulator control input | Connect to AGND when not used |
| 5 | AGND | Ground | Analog ground | |
| 6 | VBG | Analog Output | Reference bypass output | |
| 7 | INA− | Analog Input | Channel A negative input | |
| 8 | INA+ | Analog Input | Channel A positive input | |
| 9 | INB− | Analog Input | Channel B negative input | |
| 10 | INB+ | Analog Input | Channel B positive input | |
| 11 | PD_SCK | Digital Input | Power-down control and serial clock input | Power down when high active |
| 12 | DOUT | Digital Output | Serial data output | |
| 13 | XO | Digital I/O | Crystal I/O | NC when not used |
| 14 | XI | Digital Input | Crystal I/O or external clock input | 0: use on-chip oscillator |
| 15 | RATE | Digital Input | Output data rate control | 0: 10Hz; 1: 80Hz |
| 16 | DVDD | Power | Digital supply: 2.6 ~ 5.5V | Must be same voltage as MCU logic (3.3V) |

> On the common **HX711 breakout module** many of these pins are internally wired. You only need to connect: VCC, GND, E+, E−, A+, A−, DOUT (DT), and SCK (PD_SCK).

---

## Power Supply Considerations

- The HX711 can run from 3.3 V and/or 5 V; **this project uses 3.3V for logic (DVDD)** to be compatible with the ESP32's GPIO voltage.
- Keep power and signal traces separate on the PCB/breadboard.
- The **AVDD output pin** (excitation voltage for the bridge) follows the supply voltage, so at 5V the bridge is excited with ~4.3V.

---

## Channel and Gain Selection

The HX711 supports two input channels with different gain settings:

| Channel | Gain | Input range (at 3.3 V supply) |
| --------- | ------ | ------------------------------- |
| A | 128 | ±20 mV |
| A | 64 | ±40 mV |
| B | 32 | ±80 mV |

This project always uses **Channel A, Gain 128** (`HX711_GAIN_A_128`) for maximum resolution. The gain is selected by the number of extra SCK pulses sent after the 24 data bits of each conversion (see next section).

---

## Output Data Rate

The RATE pin controls the conversion speed:

| RATE pin level | Conversions per second |
| ---------------- | ------------------------ |
| LOW (or floating) | 10 Hz |
| HIGH | 80 Hz |

At 10 Hz with 10-sample averaging, one calibrated reading takes ~1 second.
At 80 Hz with 10-sample averaging, one reading takes ~125 ms.

> On most breakout modules the RATE pin is pulled LOW by default (10 Hz). The driver does not currently control RATE — wire it directly if 80 Hz is needed.

---

## Serial Communication Protocol

The HX711 uses a **custom 2-wire synchronous serial protocol** driven entirely by the master (ESP32). No standard SPI/I2C peripheral is used; all timing is implemented in software (bit-banging).

### Timing Diagram

```text
DOUT  ─────┐                                                            ┌─────
           │   Conversion    │<──────────── 24 data bits ──────────────>│
           └─────────────────┘
               (DOUT LOW                                                  (DOUT HIGH
                = ready)                                                   after 24+N pulses)

SCK   ──────────────────────┐ ┐ ┐ ┐ ┐ ┐ ... ┐ ┐ ┐ ┐ (gain pulses) ┐ ┐ ┐
                            └ └ └ └ └ └     └ └ └ └               └ └ └
                            │ Bit 23 (MSB)           Bit 0 (LSB) │

T1 (SCK HIGH width) ≥ 0.2 µs
T2 (SCK LOW  width) ≥ 0.2 µs
T3 (DOUT valid after SCK falls) ≤ 0.1 µs — data is stable before host samples
```

### Data Format

The HX711 outputs a **24-bit two's complement** value, MSB first. After sign extension to 32 bits, the value ranges from −8 388 608 to +8 388 607.

Example:

```text
Received bits: 0b 0000 0110 1001 1110 0000 1010  (hex: 0x069E0A)
Decimal: 432 650
Meaning: 432 650 raw counts above the negative full-scale
```

### Gain-Select Pulse Count

After the 24 data bits are clocked out, the master sends **1, 2, or 3 additional SCK pulses** to select the gain for the *next* conversion:

| Extra pulses | Next conversion gain |
| --- | --- |
| 1 | Channel A, gain 128 |
| 2 | Channel B, gain 32 |
| 3 | Channel A, gain 64 |

In the driver this is implemented as:

```c
for (int i = 0; i < (int)dev->cfg.gain; i++) {
    hx711_clock_pulse(dev);
}
```

where `dev->cfg.gain` is one of the `hx711_gain_t` enum values (1, 2, or 3).

---

## Power-Down Mode

Holding PD_SCK HIGH for more than **60 µs** puts the HX711 into power-down mode, drawing < 1 µA. The driver implements this as:

```c
gpio_set_level(sck_pin, 1);
ets_delay_us(65);   // > 60 µs
```

To wake up, drive PD_SCK LOW. The HX711 requires approximately **400 ms** after power-up for the internal oscillator and analog circuitry to stabilise. The first sample after wake-up should be discarded or the measurement task should delay before reading.

---

## Noise and Resolution

At 24-bit resolution the theoretical LSB size is:

```text
LSB = V_FS / 2^24 / Gain
    = 20 mV / 16 777 216 / 128
    ≈ 0.000 000 93 V  (< 1 nV per count)
```

In practice, thermal noise, board layout, and power supply noise limit effective resolution to roughly **20–21 effective bits**, which corresponds to:

```text
Effective counts ≈ 2^20 = 1 048 576
Weight resolution ≈ 200 000 g / 1 048 576 ≈ 0.19 g
```

**Techniques used in this project to reduce noise:**

1. **Multi-sample averaging** — `hx711_read_average()` with `CONFIG_SCALE_SAMPLES = 10` averages out random noise, improving SNR by √10 ≈ 3×.
2. **Zero threshold** — `CONFIG_ZERO_THRESHOLD_G = 2.0` suppresses sub-2 g fluctuations around tare.
3. **Interrupt-disabled clock sequence** — `portDISABLE_INTERRUPTS()` during the 24-bit read prevents ESP32 task switches from stretching the SCK pulse and corrupting the data.

---

## Calibration Mathematics

Raw ADC values are converted to physical weight using two parameters:

### 1. Tare Offset

Captured with no load on the scale:

```text
tare = average_raw_counts_with_empty_platform
```

### 2. Scale Factor

Captured with a known reference weight W_ref on the platform:

```text
raw_loaded = average_raw_counts_with_W_ref
delta      = raw_loaded - tare
scale      = delta / W_ref      [units: counts per lb]
```

### Weight Calculation

```text
weight_lb = (raw_reading - tare) / scale
```

**Worked example:**

| Step | Value |
| ------ | ------- |
| Tare (empty) | −47 382 counts |
| Loaded with 1000 g | 383 618 counts |
| Delta | 431 000 counts |
| Scale factor | 431 000 / 1000 = **431.0 counts/g** |
| Reading under unknown load (420 000 counts) | (420 000 − (−47 382)) / 431.0 = **1084.5 g** |

---

## Driver Implementation Notes

### Why IRAM?

The `hx711_clock_pulse()` helper is declared `IRAM_ATTR` (placed in internal RAM). On the ESP32, flash cache misses can stall instruction fetch for 20–100 µs — far longer than the required SCK cycle time of ~2 µs. Placing the hot path in IRAM guarantees timing accuracy regardless of flash activity.

### Why `portDISABLE_INTERRUPTS()`?

The 24 + N clock pulse sequence must complete without interruption. An ISR firing mid-sequence would hold SCK HIGH for the ISR duration, which could accidentally trigger power-down (> 60 µs) or corrupt the bit stream. Interrupts are re-enabled immediately after the final gain-select pulse.

### Why `ets_delay_us()` Instead of `vTaskDelay()`?

`vTaskDelay()` has a minimum resolution of one FreeRTOS tick (1 ms at 1000 Hz). The SCK duty cycle requires ~1 µs high and ~1 µs low. `ets_delay_us()` is a ROM-based busy-wait loop that provides microsecond accuracy without a context switch.

### Sign Extension

The raw 24-bit value is stored in a `uint32_t` during bit accumulation. It must be sign-extended to `int32_t` before arithmetic:

```c
if (data & 0x800000U) {   // bit 23 = sign bit
    data |= 0xFF000000U;  // extend sign to bits 31–24
}
*raw = (int32_t)data;
```

Without this step, negative readings (object pulling the scale upward) would appear as large positive numbers.

---

## Common Mistakes

| Symptom | Likely Cause | Fix |
| --------- | ------------- | ----- |
| Always reads max positive | A+ / A− swapped | Swap the bridge signal wires |
| Always reads max negative | E+ / E− swapped | Swap the excitation wires |
| Readings jump erratically | Loose connection or poor ground | Check all solder joints; add decoupling cap |
| Scale factor appears correct but weight drifts | Temperature coefficient of load cells | Re-tare after warm-up; use precision cells |
| `ESP_ERR_TIMEOUT` on every read | DOUT never goes LOW | Check VCC; verify SCK is not stuck HIGH; check wiring |
| Reading is correct sign but wrong magnitude | Wrong scale factor | Re-calibrate with a known weight |
| Readings stable but offset from zero | Tare not set | Call `hx711_tare()` with empty platform |
| Reading doubles under known weight | Two cells wired in parallel instead of bridge | Re-wire as full bridge (see wiring section) |

---

## Datasheet Reference

- **HX711 Datasheet** (Avia Semiconductor): [https://cdn.sparkfun.com/datasheets/Sensors/ForceFlex/hx711_english.pdf](https://cdn.sparkfun.com/datasheets/Sensors/ForceFlex/hx711_english.pdf)
-- **ESP32 Technical Reference Manual**: [https://www.espressif.com/sites/default/files/documentation/esp32_technical_reference_manual_en.pdf](https://www.espressif.com/sites/default/files/documentation/esp32_technical_reference_manual_en.pdf)
-- **ESP-IDF GPIO Driver API**: [https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/gpio.html](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/gpio.html)

---

*This document is part of the ESP32 Digital Scale project. See [README.md](../README.md) for setup and usage instructions.*
