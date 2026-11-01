# Video protocol

Worked out for interoperability by static analysis of the car's Android app.
**This has not yet been checked against a live car.** The code is tested against
`test/fake_car.dart`, which was written from this same document, so those tests
show the app is self-consistent rather than that the car agrees. Field names are
descriptive guesses where marked.

There's no pairing, login or encryption in the video path.

## Connection

The car is at `192.168.169.1`. The app runs both camera families at once, from
two ephemeral UDP sockets, and shows whichever answers.

| | BL608 | BL618 |
| --- | --- | --- |
| Video port | 8800 | 8801 |
| "Busy" notice, received locally on UDP | 10010 | 10011 |
| Hello interval | at least 101 ms | at least 201 ms |
| Ack timing | every 25 ms or more | over 50 ms since the last ack and over 25 ms since the last fragment |
| Frame payload | scan data only | complete JPEG |
| Largest frame | 1024 fragments | 512 fragments |
| Late frames | waits for a resend | skipped once a newer frame completes |
| Default quality bytes | 50, 75, 20, 45 | 25, 50, 8, 24 |

If no fragment arrives for 3 seconds, all state resets and the hello restarts.

A 5-byte datagram starting `busy` on the local busy port means another phone is
connected.

## Hello (app to car)

`EF 00 04 00`, repeated until the first video fragment arrives.

## Video fragment (car to app)

Integers are little-endian. Datagrams whose length doesn't match the length
field are dropped.

| Offset | Size | Field |
| --- | --- | --- |
| 0x00 | 1 | `0x93` |
| 0x01 | 1 | Type: `1` fragment, `2` ack (BL618), `4` control message |
| 0x02 | 2 | Datagram length |
| 0x08 | 8 | Frame sequence number, starting at 1 |
| 0x18 | 8 | Frames the car has seen acknowledged (inferred) |
| 0x20 | 4 | Fragment index |
| 0x24 | 4 | Fragment count |
| 0x28 | 4 | Frame size in bytes |
| 0x2C | 2 | Width |
| 0x2E | 2 | Height |
| 0x30 | 1 | JPEG quality: 5, 10, 25, 50, 75 or 100 |
| 0x38 | up to 1024 | Payload |

Every fragment holds 1024 bytes except possibly the last.

Frame N uses slot `(N + 3) & 3` of four. A slot accepts a new frame only if it's
idle and last held frame N-4, or is unused and N is below 5. Frames are released
strictly in sequence order, starting from 1.

## Rebuilding a BL608 JPEG

Output is `header + payload + FF D9`. The 605-byte header is baseline JPEG:

- SOI
- two quantisation tables: ITU T.81 K.1 and K.2 scaled by the IJG quality formula
- SOF0 with the frame's height and width, three components, no subsampling
- the four Huffman tables from T.81 K.3 to K.6
- SOS, with no restart interval

`test/protocol_test.dart` checks the generated header against SHA-256 digests of
the app's own headers at all six qualities.

## Ack (app to car)

| Offset | Size | Field |
| --- | --- | --- |
| 0x00 | 2 | `EF 02` |
| 0x02 | 2 | Datagram length |
| 0x04 | 4 | `02 02 00 01` |
| 0x08 | 1 | Block count |
| 0x0C | 86 | Command area, zero here since the app sends no commands |
| 0x52 | 4 | Quality 1, quality 2, threshold 1, threshold 2 |
| 0x56 | 1 | Camera index: `0` is the main camera |
| 0x58 | | Blocks |

Each block is:

| Offset | Size | Field |
| --- | --- | --- |
| 0x00 | 8 | Frame sequence number |
| 0x08 | 4 | `0` receiving, `1` received, `2` skipped, `3` requesting this frame |
| 0x0C | 4 | Block length, including any bitmap |
| 0x10 | | Bitmap of received fragments in 32-bit words, for states 0 to 2 |

Bits past the end of the frame are set to 1. A state 3 request for the next
expected frame is added when every other block is finished.

The meanings of the states are inferred from how the app builds them.
