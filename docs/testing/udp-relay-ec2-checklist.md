# EC2 UDP relay checklist

## Cel

Ta checklista sluzy do potwierdzenia trzech rzeczy naraz:

- UDP relay jest uruchomiony,
- UDP z klientow WireGuard nie timeoutuje przez lokalny blad na EC2,
- UDP nie wychodzi bokiem bezposrednio przez AWS IP.

## 1. Stan sterowania

Na EC2 uruchom:

```bash
sudo wireguard-egress status
sudo systemctl status wg-residential-udp-relay.service --no-pager
sudo journalctl -u wg-residential-udp-relay.service -n 50 --no-pager
```

Oczekiwany wynik:

- `SOCKS5 UDP support: true`,
- `UDP relay service: active`,
- brak powtarzajacych sie bledow typu missing config albo missing `sing-box`.

## 2. Plumbing na EC2

Na EC2 uruchom:

```bash
sudo iptables -t mangle -S WG_UDP_PROXY
sudo iptables -S INPUT | grep -- '--mark 0x1/0x1'
ip rule show
ip route show table 100
```

Oczekiwany wynik:

- istnieje chain `WG_UDP_PROXY`,
- `INPUT` przepuszcza pakiety z `mark 0x1/0x1`,
- istnieje wpis `fwmark 0x1/0x1 lookup 100`,
- tabela `100` ma `local 0.0.0.0/0 dev lo`.

Jesli tego nie ma, problem jest lokalnie w firewallu albo w reaplikacji konfiguracji.

## 3. Nasluch relay

Na EC2 uruchom:

```bash
sudo ss -lunp | grep 12346
```

Jesli uzywasz innego portu niz domyslny, podstaw swoj `RESIDENTIAL_PROXY_UDP_LOCAL_PORT`.

Oczekiwany wynik:

- widzisz proces relay nasluchujacy na lokalnym porcie UDP,
- port zgadza sie z wartoscia zapisana przez `wireguard-egress status`.

## 4. Test ruchu od klienta

Z klienta za WireGuard wygeneruj ruch UDP, na przyklad:

- test WebRTC w przegladarce,
- polaczenie Zoom,
- zapytanie DNS po UDP do zewnetrznego resolvera, jesli taki test celowo wykonujesz.

W tym samym czasie na EC2 uruchom:

```bash
sudo journalctl -u wg-residential-udp-relay.service -f --no-pager
```

Oczekiwany wynik bez leaku i z poprawnym routingiem przez proxy:

- widzisz `inbound/tproxy[tproxy-udp-in]: inbound packet connection to X:53`,
- widzisz `router: match[...] => route(residential-socks5)`,
- widzisz `outbound/socks[residential-socks5]: outbound packet connection to X:53`.

To jest bardziej wiarygodne niz sam `tcpdump`, bo przy `sing-box` + `SOCKS5 UDP ASSOCIATE` sam obraz socketow i pakietow na EC2 moze byc mylacy.

## 5. Jak odroznic timeout od leaku

Sytuacja A: klient ma timeout, a `journalctl` nie pokazuje zadnych wpisow `inbound/tproxy`.

Wniosek: relay nie pracuje, `TPROXY` nie przechwytuje pakietow albo firewall nadal blokuje pakiety z `mark 0x1/0x1` przed lokalnym socketem relay.

Sytuacja B: klient ma timeout, ale `journalctl` pokazuje `inbound/tproxy` i `outbound/socks` dla tego samego celu.

Wniosek: brak leaku; problem jest dalej, najczesciej w relay, configu `sing-box` albo po stronie providera `SOCKS5 UDP ASSOCIATE`.

Sytuacja C: klient dziala, a `journalctl` nie pokazuje `route(residential-socks5)` albo wiesz, ze ruch wychodzi z AWS poza torem `sing-box`.

Wniosek: to nie jest poprawny stan; ruch obchodzi proxy.

## 6. Minimum przed uznaniem testu za zaliczony

Test uznaj za zaliczony dopiero wtedy, gdy jednoczesnie:

- `wg-residential-udp-relay.service` jest aktywny,
- `WG_UDP_PROXY` i table `100` sa obecne,
- klient generuje ruch UDP bez timeoutu,
- na uplinku EC2 nie widac bezposredniego UDP do internetu poza upstream proxy.