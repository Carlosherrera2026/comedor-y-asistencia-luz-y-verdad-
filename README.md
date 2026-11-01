# Comedor - Tarjeta con saldo (RFID) + Huella + WiFi → Cloud Firestore

Este proyecto conecta el ESP32 a tu red WiFi y usa **dos lectores**:

- **Tarjeta RFID (RC522)** → paga la comida: descuenta **12 Bs** del saldo de la tarjeta.
- **Huella (AS606)** → confirma que el estudiante **recibió** su comida.

Todo se guarda en **Cloud Firestore** (proyecto `asistenciarfid-778d2`).

## Flujo

```
1) PAGO CON TARJETA
   - El equipo busca la tarjeta en la colección "tarjetas" por su número (uidTarjeta).
   - Si el saldo >= 12 Bs -> descuenta 12 Bs y crea un pago "pendiente" en "comedor_pagos".
   - Si el saldo es insuficiente, o la tarjeta no está registrada -> "denegado".
   - El descuento y la creación del pago se hacen en UNA sola transacción atómica
     (endpoint :commit de Firestore): si algo falla, no se descuenta nada.

2) CONFIRMACIÓN CON HUELLA
   - Cuando el estudiante recoge la comida, coloca el dedo.
   - Se busca el pago "pendiente" de esa huella (idHuella) y se marca como "entregado".
   - Si hay más de un pago pendiente, se confirma el más reciente.
```

> El pago y la confirmación pueden estar separados por mucho tiempo, o casi seguidos.

## 1. Conexiones de los lectores

### Sensor de huella AS606 (UART)

| AS606          | ESP32              |
|----------------|--------------------|
| Negro (GND)    | GND                |
| Rojo (VCC)     | 5V                 |
| Verde (TX)     | GPIO16 (RX2)       |
| Blanco (RX)    | GPIO17 (TX2)       |

### Lector RFID RC522 (SPI) — alimentar a 3.3V

| RC522   | ESP32   |
|---------|---------|
| 3.3V    | 3.3V    |
| GND     | GND     |
| SDA/SS  | GPIO5   |
| SCK     | GPIO18  |
| MOSI    | GPIO23  |
| MISO    | GPIO19  |
| RST     | GPIO22  |

> ⚠️ El RC522 es de **3.3V**. No lo alimentes con 5V o se puede dañar.

### LED verde / LED rojo / buzzer

| Componente      | ESP32              | Notas                                  |
|-----------------|--------------------|----------------------------------------|
| LED verde       | GPIO26             | Anodo al GPIO, cátodo a GND (resistencia 220 Ω) |
| LED rojo        | GPIO27             | Anodo al GPIO, cátodo a GND (resistencia 220 Ω) |
| Buzzer          | GPIO25             | Módulo de 3 pines: VCC, GND, IO        |

> El LED se enciende **por el cátodo hacia GND** (o al revés si tu módulo ya
> trae la resistencia y el LED inverted; si se enciende al revés, invierte los
> `digitalWrite` de `senalExito()` / `senalError()`).
>
> **Buzzer de 2 pines (pasivo):** pon `BUZZER_ACTIVO = false` en `src/main.cpp`
> y el código usará `tone()` a 2000 Hz. Con **módulo de 3 pines (activo)** déjalo
> en `true` (solo enciende/apaga).

## Comportamiento de los avisos

| Situación                                                | LED   | Buzzer              |
|----------------------------------------------------------|-------|---------------------|
| Pago con tarjeta correcto                                | verde | 1 sonido de 0.5 s   |
| Entrega confirmada con huella                            | verde | 1 sonido de 0.5 s   |
| Tarjeta no registrada                                    | rojo  | 3 sonidos de 0.5 s  |
| Saldo insuficiente                                       | rojo  | 3 sonidos de 0.5 s  |
| Error al descontar el saldo o al crear el pago           | rojo  | 3 sonidos de 0.5 s  |
| Tarjeta sin huella registrada (la entrega no se podría confirmar) | rojo  | 3 sonidos de 0.5 s  |
| Huella desconocida (no registrada)                       | rojo  | 3 sonidos de 0.5 s  |
| Huella reconocida pero **sin** pago pendiente             | rojo  | 3 sonidos de 0.5 s  |
| Error al marcar el pago como entregado                   | rojo  | 3 sonidos de 0.5 s  |
| **No se detectó ninguna lectura** (nadie pone nada)      | –     | **sin sonido**      |

## 2. Configurar WiFi y datos

### 2.1 Credenciales (`src/secrets.h`)

La API key y la contraseña del WiFi **no** están en `main.cpp`, viven en
`src/secrets.h`, que está en el `.gitignore` para que nunca se suban al
repositorio. La primera vez:

```cmd
copy src\secrets.h.example src\secrets.h
```

Y completa en `src/secrets.h`:

```cpp
const char* WIFI_SSID = "robo25";          // red 2.4 GHz (abierta, sin clave)
const char* WIFI_PASS = "";
const char* API_KEY    = "...";             // API key de Firebase
const char* PROJECT_ID = "asistenciarfid-778d2";
```

### 2.2 Ajustes del programa (`src/main.cpp`)

```cpp
const int   MONTO_COMIDA = 12;             // Bs que se descuentan por comida
const char* DEVICE_ID  = "comedor-esp32";

const int  PIN_BUZZER    = 25;              // buzzer
const int  PIN_LED_VERDE = 26;              // LED de exito
const int  PIN_LED_ROJO  = 27;              // LED de error
const bool BUZZER_ACTIVO = true;           // true = módulo de 3 pines
```

> El ESP32 **no** se conecta a redes de 5 GHz.
> No cambies los pines a la ligera: GPIO 34-39 son solo entradas y 12/15/0/2
> tienen funciones de arranque.

## 3. Reglas de Firestore (IMPORTANTE)

En la consola de Firebase: **Compilación → Firestore Database → pestaña "Reglas"**.

Estas reglas son **más estrictas** que las originales y siguen funcionando con
el firmware:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // --- tus reglas actuales (asistencia, etc.) se quedan igual ---

    // Accesos y confirmaciones (el equipo solo escribe)
    match /comedor/{documento} {
      allow read: if true;
      allow create: if true;
      allow update, delete: if false;
    }

    // Intentos no reconocidos / anomalías
    match /comedor_no_reconocidas/{documento} {
      allow read: if true;
      allow create: if true;
      allow update, delete: if false;
    }

    // Tarjetas con saldo.
    // El equipo SOLO puede cambiar "saldo": no puede tocar el nombre,
    // el idHuella ni el estudiante_id.
    match /tarjetas/{documento} {
      allow read: if true;
      allow create: if true;
      allow update: if request.resource.data.diff(resource.data)
                        .affectedKeys().hasOnly(['saldo']);
      allow delete: if false;
    }

    // Pagos del comedor (pendiente -> entregado).
    // Solo se puede cambiar el estado y la fecha de entrega.
    match /comedor_pagos/{documento} {
      allow read: if true;
      allow create: if true;
      allow update: if request.resource.data.diff(resource.data)
                        .affectedKeys().hasOnly(['estado', 'fecha_entrega', 'hora_entrega']);
      allow delete: if false;
    }
  }
}
```

> **Qué hace más seguro esto:** con `allow update: if true` cualquiera que tenga
> la API key podía cambiar el `saldo` de cualquier tarjeta, cambiar el
> `idHuella` de un alumno o **borrar** documentos. Con estas reglas solo se
> puede cambiar el saldo (y nada más), y **no se puede borrar nada**.

### 3.1 Restringir la API key (muy recomendable)

En **Google Cloud Console → APIs y servicios → Credenciales**, edita la API key
y en "Restricciones de aplicaciones" deja marcada solo **"Direcciones IP"** con
la IP pública del WiFi del colegio. Así, aunque la key se filtre, no sirve
desde ningún otro lado.

> ⚠️ La API key sigue siendo visible para quien tenga el firmware o el
> `secrets.h`. Para autenticación real por usuario haría falta un service
> account o un token, lo que es bastante más complejo.

## 4. Estructura de los datos

### Colección `tarjetas` (cada tarjeta es un estudiante)

| Campo           | Tipo   | Ejemplo          |
|-----------------|--------|------------------|
| `nombre`        | texto  | `Ana Rodríguez`  |
| `estudiante_id` | texto  | `EST004`         |
| `curso`         | texto  | `5to`            |
| `uidTarjeta`    | texto o número | `1901538218` (número decimal de la tarjeta) |
| `saldo`         | número | `50`             |
| `idHuella`      | número | `1`              |

> El `uidTarjeta` es el UID de la tarjeta en **decimal**. El equipo lo busca tanto
> como texto como número, así funciona con cualquiera de los dos formatos.

### Colección `comedor_pagos` (un pago por comida)

| Campo           | Tipo   | Ejemplo                    |
|-----------------|--------|----------------------------|
| `uidTarjeta`    | texto  | `1901538218`               |
| `estudiante_id` | texto  | `EST004`                   |
| `nombre`        | texto  | `Ana Rodríguez`            |
| `idHuella`      | número | `1`                        |
| `monto`         | número | `12`                       |
| `saldoAntes`    | número | `50`                       |
| `saldoDespues`  | número | `35`                       |
| `fecha` / `hora`| texto  | `2026-10-14T16:08:26-04:00`|
| `estado`        | texto  | `pendiente` / `entregado`  |
| `fecha_entrega` / `hora_entrega` | texto | (al confirmar con huella) |

> El `idHuella` se busca **como número y como texto**, así que funciona igual si
> lo guardó el firmware o si lo cargó otra aplicación como texto.
>
> No hace falta crear **ningún índice compuesto**: la consulta del pago
> pendiente usa dos igualdades (`idHuella` + `estado`), que Firestore resuelve
> con los índices automáticos. El "pago más reciente" lo elige el ESP32.

### Colección `comedor` (accesos y confirmaciones)

| Campo        | Tipo   | Cuándo                              |
|--------------|--------|-------------------------------------|
| `tipo`       | texto  | `rfid` / `huella`                   |
| `resultado`  | texto  | `acceso`, `denegado`, `entrega_confirmada`, `sin_pago_pendiente` |
| `motivo`     | texto  | `pago_comida`, `saldo_insuficiente`, `tarjeta_no_registrada`, `tarjeta_sin_huella`, `pago_confirmado`, `huella_no_reconocida`, `error_confirmacion` |
| `uidTarjeta` | texto  | solo tarjeta (número decimal)       |
| `uidHex`     | texto  | solo tarjeta (UID tal cual)         |
| `idHuella`   | número | huella                              |
| `saldoAntes` / `saldoDespues` | número | tarjeta           |
| `dispositivo`| texto  | `comedor-esp32`                     |
| `fecha` / `hora` | texto | local (UTC-4)                     |

- Las **huellas no reconocidas** van a `comedor_no_reconocidas`.

## 5. Registrar (o re-registrar) una huella

1. Abre el **Monitor Serie** (115200).
2. Escribe la letra **`e`** y pulsa Enter.
3. Sigue las instrucciones: coloca el dedo, retíralo, y colócalo otra vez.
4. Al final aparecerá: `LISTO! Huella guardada con ID #N`.

- Para **borrar todas las huellas**, escribe **`b`** y pulsa Enter.
- Ese ID (`#N`) es el que debes poner en `idHuella` de la tarjeta del estudiante.

### Comandos del Monitor Serie

| Tecla | Qué hace |
|-------|----------|
| `e` | Registrar una huella nueva |
| `b` | Borrar todas las huellas del sensor |
| `t` | Diagnóstico del lector de huella (códigos de getImage / image2Tz / search) |
| `s` | **Probar el LED y el buzzer** (verde + 1 sonido, rojo + 3 sonidos) |

> Usa `s` después de cablear los LEDs y el buzzer: no necesitas ninguna tarjeta
> ni huella para comprobar que funcionan.

## 6. Compilar y subir (VS Code + PlatformIO)

- Compilar: botón **✓**, o `pio run`.
- Subir: botón **→**, o `pio run -t upload`.
- Monitor Serie: `pio device monitor` (115200).

## Notas

- `client.setInsecure()` no verifica el certificado del servidor; es lo más simple.
- La hora se guarda en **hora local (UTC-4)** vía NTP.
- El ESP32 reinicia la búsqueda de WiFi si se cae la conexión.
- **Antirrebote: 5 segundos**, tanto para tarjetas como para huellas, para evitar
  lecturas dobles (cobrar dos veces o confirmar dos veces).
- Además, si el dedo **queda apoyado** en el sensor, las lecturas siguientes se
  ignoran hasta que se retire el dedo.
- El cobro es **atómico**: el descuento del saldo y la creación del pago van en
  la misma transacción de Firestore (`:commit`). Nunca queda saldo descontado
  sin pago, ni pago sin saldo descontado.
- Las credenciales (API key y WiFi) están en `src/secrets.h`, que está en el
  `.gitignore`. **Nunca subas ese archivo.**
