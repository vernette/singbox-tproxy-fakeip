- [Русский](#ru)
- [English](#en)

# RU

Shell скрипт для настройки sing-box на использование TProxy и FakeIP на роутере с OpenWrt.

Текущая версия скрипта настраивает sing-box версии `1.11.x`.

## Установка

```bash
sh <(wget -O - https://github.com/vernette/singbox-tproxy-fakeip/raw/master/install.sh)
```

> [!WARNING]
> Скрипт заменит файл `/etc/sing-box/config.json` **только** в том случае, если он не содержит настроек для `FakeIP` (то есть если вы запустите скрипт снова, то он пропустит замену конфига), поэтому сделайте резервную копию вашего конфига перед запуском скрипта

## После установки

После окончания работы скрипта, вам нужно изменить конфиг sing-box (изменить секцию `outbounds` на свои нужды) и перезапустить сервис sing-box:

```bash
nano /etc/sing-box/config.json # или vim /etc/sing-box/config.json
service sing-box restart
```

И всё готово!

**Обязательно** прочитать [как всё это работает](https://gist.github.com/vernette/67466961ed5882b3ff21222d1b964929)

# EN

Shell script to configure sing-box to use TProxy and FakeIP on OpenWrt router.

The current version of the script configures sing-box version `1.11.x`.

## Installation

```bash
sh <(wget -O - https://github.com/vernette/singbox-tproxy-fakeip/raw/master/install.sh)
```

> [!WARNING]
> This script will replace `/etc/sing-box/config.json` file **only** if it doesn't contain `FakeIP` settings (basically, if you will run script again it will skip config replacement), so make sure to backup your config file before running this script

## Post-Install

After script finishes, you need to make changes to the sing-box config file (change `outbounds` section to your needs) and restart sing-box service:

```bash
nano /etc/sing-box/config.json # or vim /etc/sing-box/config.json
service sing-box restart
```

And now you are ready to go!

**Must read** [on how everything works](https://gist.github.com/vernette/67466961ed5882b3ff21222d1b964929)
