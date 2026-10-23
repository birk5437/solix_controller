# Third-party notices

SOLIX Controller's protocol layer is a clean-room Swift port of *protocol facts* (endpoints, field layouts, constants)
documented in the following MIT-licensed projects. No Python code is bundled or executed.

| Project | Used for | License |
|---|---|---|
| [thomluther/anker-solix-api](https://github.com/thomluther/anker-solix-api) | Cloud login (ECDH/AES), API endpoints, MQTT envelope + hex frame format, per-model telemetry/command maps, PPS TOU plan format | MIT, © 2024 Thomas Luther |
| [thomluther/ha-anker-solix](https://github.com/thomluther/ha-anker-solix) | Behavioural documentation of PPS Time-of-Use (owner-only, 6 ranges, no gaps) | MIT, © 2024 Thomas Luther |
| [flip-dots/SolixBLE](https://github.com/flip-dots/SolixBLE) | BLE manufacturer record layout (company id 0xFFFF), identifier service UUIDs, product_type → model mapping | MIT, © 2026 Harvey Lelliott |

MIT License (applies to each of the above, with the respective copyright holder):

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
> rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
> persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and
> this permission notice shall be included in all copies or substantial portions of the Software.
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
> WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.

Anker and SOLIX are trademarks of Anker Innovations Limited. This project is not affiliated with or endorsed by Anker.
The Anker cloud API is undocumented and unofficial; Anker may change it at any time.
The public key embedded for login is Anker's *server* public key (as published in anker-solix-api); no private
keys of any third party are used.
