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
ip rule show
ip route show table 100
```

Oczekiwany wynik:

- istnieje chain `WG_UDP_PROXY`,
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
UPLINK_IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"
sudo tcpdump -ni "${UPLINK_IFACE}" udp and not port 51820
```

Oczekiwany wynik bez leaku:

- widzisz ruch UDP z EC2 tylko do adresu i portu upstream proxy,
- nie widzisz bezposrednich pakietow UDP do losowych hostow internetowych.

Jesli widzisz pakiety UDP bezposrednio do docelowych hostow, to jest leak i trzeba zatrzymac test.

## 5. Jak odroznic timeout od leaku

Sytuacja A: klient ma timeout, a na uplinku EC2 nie ma zadnego UDP do upstream proxy.

Wniosek: relay nie pracuje albo `TPROXY` nie przechwytuje pakietow.

Sytuacja B: klient ma timeout, ale na uplinku EC2 widzisz UDP tylko do upstream proxy.

Wniosek: brak leaku; problem jest dalej, najczesciej w relay, configu `sing-box` albo po stronie providera `SOCKS5 UDP ASSOCIATE`.

Sytuacja C: klient dziala, a na uplinku EC2 widzisz UDP do innych hostow niz upstream proxy.

Wniosek: to nie jest poprawny stan; ruch obchodzi proxy.

## 6. Minimum przed uznaniem testu za zaliczony

Test uznaj za zaliczony dopiero wtedy, gdy jednoczesnie:

- `wg-residential-udp-relay.service` jest aktywny,
- `WG_UDP_PROXY` i table `100` sa obecne,
- klient generuje ruch UDP bez timeoutu,
- na uplinku EC2 nie widac bezposredniego UDP do internetu poza upstream proxy.