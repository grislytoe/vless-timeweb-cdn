# Происхождение

- Админка, локальный root-менеджер, установщик, проверки и интерфейс адаптированы из
  https://github.com/grislytoe/vless-server-kit/tree/43f2fdbbaa7683a7a78d2e1c27de35e77a671b10
  по поручению владельца репозитория grislytoe. Эта ссылка не означает автоматической
  лицензии на весь исходный проект; MIT ниже относится к заимствованному CDN-профилю.
- Профиль `timeweb_extra()` в `config.py` и логика пути `/index.json` адаптированы из
  `wpp_cdn.py` проекта https://github.com/POLESNIESOVETI12/web-panel-proxy
  ревизии `a4c7ae2402a4a6f37987c2c40d0f0249e6fd3b5a`.
- Схема настройки: https://youtu.be/QQ1WVviBe2A . Видео не является гарантией доступности CDN.
- Xray, Nginx, Certbot и Python-пакеты скачиваются из указанных в установщике официальных
  источников и сохраняют собственные лицензии. Бинарные файлы не включены в репозиторий.

## Лицензия заимствованного CDN-профиля

MIT License

Copyright (c) 2026 POLESNIESOVETI12

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
