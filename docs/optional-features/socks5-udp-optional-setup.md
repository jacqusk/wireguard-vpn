# SOCKS5 UDP Support (Optional)

## Co daje ta opcja

Domyslnie `ENABLE_SOCKS5_UDP_SUPPORT=false`. To oznacza:
- UDP w trybie `direct` dziala normalnie,
- TCP w trybie `residential-proxy` idzie przez proxy,
- UDP w trybie `residential-proxy` jest blokowany fail-closed.

Po wlaczeniu `ENABLE_SOCKS5_UDP_SUPPORT=true` projekt robi dwie rzeczy:
- zapisuje ustawienia UDP w `/etc/default/wireguard-egress`,
- przechwytuje UDP klientow WireGuard przez `TPROXY` do lokalnego portu relay.

To nie uruchamia samego relay. Wbudowana usluga `wg-residential-proxy.service` nadal obsluguje tylko TCP przez `redsocks`.

## Kiedy ma sens

Tylko jesli jednoczesnie:
1. upstream proxy to `socks5`,
2. provider wspiera `SOCKS5 UDP ASSOCIATE`,
3. na EC2 uruchomisz osobny relay UDP z obsluga transparentnego przechwycenia `TPROXY`.

Jesli ktorys z tych warunkow nie jest spelniony, zostan przy domyslnym TCP-only.

## Konfiguracja

Przyklad zapisania profilu:

```bash
sudo wireguard-egress configure \
  --host proxy.example.net \
  --port 1080 \
  --type socks5 \
  --username USER \
  --password PASS \
  --local-port 12345 \
  --enable-udp true \
  --udp-local-port 12346
```

Po `enable` firewall bedzie:
- dalej przekierowywal TCP do `RESIDENTIAL_PROXY_LOCAL_PORT`,
- przechwytywal UDP klientow do `RESIDENTIAL_PROXY_UDP_LOCAL_PORT` przez `TPROXY`.

## Czego jeszcze potrzebujesz

Musisz uruchomic osobny relay UDP, ktory:
- nasluchuje na `RESIDENTIAL_PROXY_UDP_LOCAL_PORT`,
- obsluguje transparentne pakiety przechwycone przez `TPROXY`,
- wysyla je dalej przez `SOCKS5 UDP ASSOCIATE`.

Projekt instaluje do tego gotowy wrapper systemd:
- skrypt `/usr/local/sbin/run-residential-udp-relay.sh`,
- usluge `wg-residential-udp-relay.service`.

Domyslnie wrapper oczekuje:
- binarki `sing-box` w `PATH`,
- pliku config `/etc/sing-box/wg-residential-udp-relay.json`.

Praktyczna instrukcja instalacji `sing-box` na Ubuntu 24.04 i kolejnosc uruchomienia relay jest w [sing-box-ubuntu-24.04-udp-relay-setup.md](sing-box-ubuntu-24.04-udp-relay-setup.md).

Praktycznie oznacza to narzedzie klasy:
- `sing-box` z odpowiednim inbound `tproxy`,
- `xray` z transparentnym inbound dla UDP,
- inne rozwiazanie, ktore potrafi przyjac przechwycony UDP przez `TPROXY`.

Bez takiego relay pakiety beda timeoutowac, ale nadal nie wyjda przez AWS IP.

## Ograniczenia

- To nadal jest opcja zaawansowana i wymaga dodatkowego komponentu poza projektem.
- `http-connect` nie obsluguje tego trybu; UDP wymaga `socks5`.
- Projekt dostarcza usluge systemd `wg-residential-udp-relay.service` jako wrapper, ale sama binarka `sing-box` i plik config `/etc/sing-box/wg-residential-udp-relay.json` musza byc zapewnione osobno.

## Test operacyjny

Po wlaczeniu opcji sprawdz:

```bash
sudo wireguard-egress status
sudo systemctl status wg-residential-udp-relay.service --no-pager
sudo iptables -t mangle -S
ip rule show
ip route show table 100
```

Oczekiwany wynik:
- widzisz `SOCKS5 UDP support: true`,
- widzisz albo gotowy, albo brakujacy stan configu relay w `wireguard-egress status`,
- istnieje chain `WG_UDP_PROXY` w tabeli `mangle`,
- istnieje `fwmark 0x1/0x1 lookup 100`,
- tabela `100` routuje `local 0.0.0.0/0 dev lo`.

Pelna checklista EC2 do odroznienia timeoutu od leaku jest w [udp-relay-ec2-checklist.md](../testing/udp-relay-ec2-checklist.md).

## Gdy cos nie dziala

Najczestsze przyczyny:
- provider nie wspiera `UDP ASSOCIATE`,
- relay UDP nie nasluchuje na `RESIDENTIAL_PROXY_UDP_LOCAL_PORT`,
- relay nie obsluguje `TPROXY`,
- ustawiono `http-connect` zamiast `socks5`.

## Podsumowanie

Ta opcja jest teraz domknieta po stronie projektu jako:
- trwala konfiguracja,
- walidacja ustawien,
- przechwycenie UDP w firewallu,
- fail-closed bez leaku przez AWS.

Ostatni element pozostaje po Twojej stronie: uruchomienie zewnetrznego relay UDP zgodnego z `TPROXY` i `SOCKS5 UDP ASSOCIATE`.
