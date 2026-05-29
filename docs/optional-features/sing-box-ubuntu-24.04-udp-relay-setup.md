# sing-box on Ubuntu 24.04 for UDP relay

## Cel

Ten dokument opisuje tylko ostatni brakujacy krok dla opcji UDP w trybie `residential-proxy`:

- instalacje `sing-box` na EC2 z Ubuntu 24.04,
- przygotowanie pliku config dla relay,
- kolejnosc uruchomienia uslugi `wg-residential-udp-relay.service`.

To jest instrukcja operacyjna. Nie zmienia nic w skryptach projektu.

## Kiedy tego potrzebujesz

Tylko jesli jednoczesnie:

1. masz `RESIDENTIAL_PROXY_TYPE=socks5`,
2. wlaczyles `ENABLE_SOCKS5_UDP_SUPPORT=true`,
3. chcesz, zeby UDP klientow nie bylo blokowane fail-closed.

Jesli zostajesz przy TCP-only, ten dokument nie jest potrzebny.

## Stan wyjsciowy

Projekt ma juz przygotowane:

- firewall `TPROXY`,
- wrapper `/usr/local/sbin/run-residential-udp-relay.sh`,
- usluge `wg-residential-udp-relay.service`,
- sprawdzanie gotowosci relay w `wireguard-egress status`.

Brakuje tylko:

- binarki `sing-box`,
- pliku `/etc/sing-box/wg-residential-udp-relay.json`.

## 1. Instalacja sing-box

Na Ubuntu 24.04 ARM64 na EC2 najprostsza jest instalacja z oficjalnego release `.deb`.

Przyklad dla aktualnego stable release `1.13.12`:

```bash
cd /tmp
curl -fsSLO "https://github.com/SagerNet/sing-box/releases/download/v1.13.12/sing-box_1.13.12_linux_arm64.deb"
sudo apt-get install -y ./sing-box_1.13.12_linux_arm64.deb
sing-box version
```

Jesli w momencie wdrozenia stable release jest nowszy, podmien tylko numer wersji w URL i nazwie pliku.

## 2. Przygotowanie katalogu config

```bash
sudo install -d -m 755 /etc/sing-box
```

## 3. Wgranie configu relay

Projekt oczekuje pliku:

```bash
/etc/sing-box/wg-residential-udp-relay.json
```

Szablon startowy znajdziesz w repozytorium:

- [../../config/sing-box/wg-residential-udp-relay.json.template](../../config/sing-box/wg-residential-udp-relay.json.template)

Skopiuj go na serwer i podmien placeholdery (`UPSTREAM_SOCKS5_HOST`, `UPSTREAM_USERNAME`, `UPSTREAM_PASSWORD`).

Config musi:

- przyjmowac UDP transparentnie przez `tproxy`,
- nasluchiwac na `RESIDENTIAL_PROXY_UDP_LOCAL_PORT` (domyslnie `12346`),
- wysylac ruch przez upstream `SOCKS5` z `UDP ASSOCIATE`.

Po wgraniu ustaw prawa:

```bash
sudo chown root:root /etc/sing-box/wg-residential-udp-relay.json
sudo chmod 600 /etc/sing-box/wg-residential-udp-relay.json
```

## 4. Kolejnosc uruchomienia na EC2

Najbezpieczniejsza kolejnosc po stronie instancji jest taka:

1. zapisz lub popraw profil proxy,
2. wlacz tryb `residential-proxy`,
3. dopiero potem uruchom relay UDP,
4. sprawdz status i firewall.

Przykladowe polecenia:

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

sudo wireguard-egress enable
sudo systemctl daemon-reload
sudo systemctl enable --now wg-residential-udp-relay.service
sudo wireguard-egress status
sudo systemctl status wg-residential-udp-relay.service --no-pager
```

## 5. Co powinienes zobaczyc

Po poprawnym uruchomieniu:

- `wireguard-egress status` pokazuje `SOCKS5 UDP support: true`,
- `wireguard-egress status` pokazuje gotowy config relay,
- `wg-residential-udp-relay.service` jest `active`,
- firewall ma `WG_UDP_PROXY`,
- istnieje `ip rule` dla `fwmark 0x1/0x1`,
- `INPUT` akceptuje pakiety UDP z `mark 0x1/0x1`, zeby `TPROXY`-owany ruch mogl dojsc do lokalnego socketu relay.

## 6. Co z automatycznym startem po restarcie EC2

Po spelnieniu dwoch warunkow:

- `sing-box` jest zainstalowany,
- `/etc/sing-box/wg-residential-udp-relay.json` istnieje,

bootstrap projektu moze sam wystartowac `wg-residential-udp-relay.service` przy starcie, jesli `EGRESS_MODE=residential-proxy` i `ENABLE_SOCKS5_UDP_SUPPORT=true`.

Czyli reczne uruchomienie robisz glownie pierwszy raz albo po zmianie configu relay.

## 7. Gdy cos nie wstaje

Najpierw sprawdz:

```bash
sing-box version
sudo systemctl status wg-residential-udp-relay.service --no-pager
sudo journalctl -u wg-residential-udp-relay.service -n 100 --no-pager
sudo wireguard-egress status
```

Jesli usluga wstaje, ale UDP nadal nie dziala poprawnie, przejdz przez [udp-relay-ec2-checklist.md](../testing/udp-relay-ec2-checklist.md).

## 8. Czego tu celowo nie automatyzowac na sile

Na tym etapie projekt nie generuje automatycznie JSON-a `sing-box`, bo to jest najbardziej wrazliwy element calego toru UDP:

- zalezy od wersji `sing-box`,
- zalezy od konkretnego modelu relay,
- zalezy od wymagan Twojego upstream proxy.

Lepiej miec jawny, recznie zweryfikowany config relay niz "magiczny" config, ktory uruchamia sie, ale nie daje pewnosci, czy UDP idzie poprawnie.