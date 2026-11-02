# Asistencia con huella AS606 + RFID RC522 -> Firestore

Firmware para el **ESP32** que registra entrada y salida de estudiantes en la
**misma base de datos que el comedor** (`asistenciarfid-778d2`).

- La **huella** funciona igual que una tarjeta RFID (sirve si se pierde la tarjeta).
- La **tarjeta RFID** se puede activar con la tecla `r` del Monitor Serie.
- **No descuenta saldo**: es un sistema independiente del comedor.

## Funcionamiento

| Momento | Qué guarda |
|---|---|
| Primera marcación del día, **antes de 07:30** | `hora_entrada`, `estado: "PRESENTE"` |
| Primera marcación del día, **desde 07:30** | `hora_entrada`, `estado: "TARDE"` |
| Segunda marcación del mismo día | `hora_salida`, `estado: "COMPLETA"` |
| Tercera marcación o siguientes | No modifica nada (aviso verde) |

Documento creado:

```
asistencias/{estudiante_id}_{YYYY-MM-DD}
```

Ejemplo: `asistencias/EST004_2026-11-02`

Campos:

| Campo | Tipo | Ejemplo |
|---|---|---|
| `estudiante_id` | texto | `EST004` |
| `nombre` | texto | `Ana Rodríguez` |
| `curso` | texto | `5to` |
| `fecha` | texto | `2026-11-02` |
| `hora_entrada` | texto | `07:12:45` |
| `hora_salida` | texto | `12:30:10` |
| `estado` | texto | `PRESENTE` / `TARDE` / `COMPLETA` |
| `origen` | texto | `esp32` |
| `metodo` | texto | `huella` / `rfid` |
| `dispositivo` | texto | `asistencia-esp32` |

### Cómo relaciona la huella con el estudiante

1. Busca `idHuella` en `estudiantes`.
2. Si no está, busca `idHuella` en `tarjetas` y toma su `estudiante_id`.
3. Con ese `estudiante_id` carga `nombre` y `curso` desde `estudiantes`.

> Si una huella no aparece como registrada, revisa que el `idHuella` del sensor
> coincida con el campo `idHuella` de la tarjeta del estudiante.

### Cómo relaciona la tarjeta con el estudiante

1. Busca el número decimal del UID en `estudiantes.rfid` y `estudiantes.rfid_alt`.
2. Si no está, lo busca en `tarjetas.uidTarjeta`.
3. También prueba `tarjetas/{uid}` como id de documento.

## Avisos LED / buzzer

| Situación | LED | Buzzer |
|---|---|---|
| Asistencia registrada (entrada o salida) | verde | 1 pitido de 0.5 s |
| Tarjeta o huella no registrada | rojo | 3 pitidos de 0.5 s |
| Error de red / Firestore | rojo | 3 pitidos de 0.5 s |
| Nadie pone dedo ni tarjeta | – | sin sonido |

## Conexiones

### Sensor de huella AS606 (UART2)

| AS606 | ESP32 |
|---|---|
| Negro (GND) | GND |
| Rojo (VCC) | 5V |
| Verde (TX) | GPIO16 (RX2) |
| Blanco (RX) | GPIO17 (TX2) |

### Lector RFID RC522 (SPI) — alimentar a 3.3V

| RC522 | ESP32 |
|---|---|
| 3.3V | 3.3V |
| GND | GND |
| SDA/SS | GPIO5 |
| SCK | GPIO18 |
| MOSI | GPIO23 |
| MISO | GPIO19 |
| RST | GPIO22 |

### LED y buzzer

| Componente | ESP32 |
|---|---|
| LED verde | GPIO26 |
| LED rojo | GPIO27 |
| Buzzer | GPIO25 |

## Configuración

`src/secrets.h` (no se sube al repositorio):

```cpp
const char* WIFI_SSID = "Galaxy A21s9E91";
const char* WIFI_PASS = "Carlos2008";
const char* API_KEY    = "...";
const char* PROJECT_ID = "asistenciarfid-778d2";
```

## Comandos del Monitor Serie (115200)

| Tecla | Acción |
|---|---|
| `r` | Activar / desactivar el lector RFID |
| `e` | Registrar una huella nueva |
| `b` | Borrar todas las huellas del sensor |
| `t` | Diagnóstico del lector de huella |
| `s` | Probar LED verde/rojo y buzzer |

> **Modo de prueba actual:** al arrancar, el RFID queda desactivado
> (`rfidActivo = false`). Solo funciona la huella. Escribe `r` para activar el
> lector de tarjetas cuando esté probado.

## Compilar y subir

```bash
pio run
pio run -t upload --upload-port COM3
pio device monitor --port COM3 --baud 115200
```

## Notas

- Antirrebote de **0.5 segundos** para tarjetas y huellas.
- Si el dedo queda apoyado, se ignora hasta retirarlo.
- La hora se sincroniza por NTP y se guarda en **UTC-4** (Bolivia).
- El cobro del comedor no se toca desde este firmware.
