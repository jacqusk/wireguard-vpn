# GL.iNet WireGuard guide

## Cel

Ten dokument opisuje praktyczny wariant wdrozenia klienta WireGuard na routerze GL.iNet w projekcie VPN na AWS.

W tym wariancie:

- EC2 w AWS jest serwerem WireGuard,
- router GL.iNet AX3000 jest glownym klientem WireGuard,
- urzadzenia podpiete do routera nie potrzebuja wlasnej aplikacji VPN,
- router ma blokowac zwykly ruch WAN, jesli tunel do AWS nie dziala,
- ten sam serwer moze obslugiwac dodatkowe klienty WireGuard, na przyklad telefony.

## Co powinien wspierac router

Minimalne wymagania:

- klienta WireGuard,
- import profilu WireGuard albo konfiguracje reczna,
- wlaczenie tunelu automatycznie po starcie,
- mozliwosc wymuszenia ruchu wszystkich klientow przez VPN,
- kill switch lub blokade ruchu poza VPN,
- lokalny panel administracyjny dostepny z telefonu albo laptopa.

## Bezpieczne zalozenia dla wersji 1

Zeby uproscic konfiguracje GL.iNet:

- uzywaj Elastic IP AWS jako `Endpoint`,
- trzymaj staly port `51820/UDP`,
- kieruj caly ruch przez tunel,
- nie wlaczaj zadnego fallbacku na zwykly WAN dla klientow LAN,
- admin panel routera trzymaj tylko w LAN.

## Przygotowanie konfiguracji klienta

Masz dwa praktyczne zrodla konfiguracji:

1. [wireguard-client-single-device.conf.template](../../config/wireguard/wireguard-client-single-device.conf.template)
2. `/root/wireguard-client.conf` wygenerowany na instancji EC2

Przy wariancie multi-peer dodatkowe szablony sa generowane do katalogu `/root/wireguard-clients/`.

Plan adresacji peerow jest opisany w [wireguard-peer-layout.md](../architecture/wireguard-peer-layout.md).

Uzupelnij pola:

- `PrivateKey` - prywatny klucz klienta przechowywany na routerze,
- `PublicKey` - publiczny klucz serwera z EC2,
- `PresharedKey` - klucz PSK z serwera,
- `Endpoint` - Elastic IP instancji AWS,
- `AllowedIPs = 0.0.0.0/0`, jesli caly ruch ma isc przez VPN,
- `PersistentKeepalive = 25`.

## Pierwsza konfiguracja GL.iNet

1. Podlacz router do zasilania.
2. Podepnij go do uplinku internetowego po Wi-Fi albo Ethernet.
3. Polacz telefon albo laptop z siecia LAN lub Wi-Fi routera.
4. Otworz lokalny panel administracyjny GL.iNet.
5. Ustaw mocne haslo administratora.
6. Jesli to mozliwe, zaktualizuj firmware przed konfiguracja VPN.
7. Wylacz zdalny dostep administracyjny od strony WAN, jesli jest dostepny.

## Konfiguracja WireGuard w GL.iNet

Dokladne nazwy zakladek moga sie roznic miedzy modelami i wersjami firmware, ale logika jest taka sama.

Najczesciej szukaj sekcji typu:

- `VPN`,
- `WireGuard Client`,
- `VPN Dashboard`,
- `VPN Policies`.

Kroki:

1. Dodaj nowy profil WireGuard.
2. Zaimportuj profil z pliku albo wpisz dane recznie.
3. Ustaw `Endpoint` na Elastic IP AWS.
4. Ustaw `AllowedIPs` tak, aby caly ruch szedl przez tunel.
5. Zapisz profil.
6. Wlacz `Auto-connect` albo rownowazna opcje automatycznego laczenia po starcie.
7. Wlacz tunel.

## Kill switch na GL.iNet

Najprostszy i preferowany wariant:

1. Wlacz opcje typu `Block Non-VPN Traffic`, `Kill Switch` albo rownowazna, jesli firmware ja udostepnia.
2. Ustaw polityke tak, aby wszyscy klienci LAN korzystali z VPN, a nie tylko wybrane urzadzenia.
3. Nie wlaczaj trybu split tunnel w wersji 1.

Jesli firmware nie daje czytelnej opcji kill switch:

1. Uzyj firewall policy routera.
2. Pozwol routerowi na WAN tylko do `AWS_ELASTIC_IP:51820/UDP`.
3. Zablokuj forwarding `LAN -> WAN`.
4. Pozwol `LAN -> WireGuard`.
5. Pozwol tylko ruch powrotny zwiazany z aktywnym tunelem.

To jest warunek krytyczny. Jesli router nie pozwala wdrozyc takiej polityki, nie spelnia zalozen projektu.

## Zalecana polityka ruchu

Dla wersji 1 polityka powinna byc prosta:

- wszystkie urzadzenia za routerem ida przez VPN,
- zaden klient LAN nie wychodzi bezposrednio przez WAN,
- sam router moze uzyc WAN tylko do zestawienia tunelu do AWS,
- panel administracyjny routera jest dostepny tylko z LAN.

## Test po konfiguracji

1. Wlacz EC2 w AWS Console Mobile App.
2. Poczekaj, az instancja bedzie `Running` i przejdzie `Status checks`.
3. Upewnij sie, ze router zestawil tunel WireGuard.
4. Podlacz urzadzenie testowe do routera.
5. Otworz strone pokazujaca publiczny adres IP.
6. Potwierdz, ze widzisz adres AWS, a nie lokalny adres sieci uplinkowej.
7. Wylacz tunel WireGuard na routerze albo zatrzymaj instancje EC2.
8. Sprawdz, czy internet za routerem zostal zablokowany.

## Codzienna obsluga

Model operacyjny ma byc prosty:

1. Startujesz instancje EC2 z telefonu w AWS Console Mobile App.
2. Router GL.iNet automatycznie zestawia tunel.
3. Laczysz urzadzenia z routerem.
4. Korzystasz z internetu przez AWS IP.
5. Zatrzymujesz EC2, gdy tunel nie jest potrzebny.

Po zatrzymaniu EC2:

- tunel powinien zniknac,
- kill switch na GL.iNet powinien zablokowac internet dla klientow,
- nic nie powinno przejsc awaryjnie przez zwykly uplink routera.

## Dodatkowe klienty WireGuard

Ten sam serwer moze obslugiwac rownoczesnie:

- AX3000 jako glowny router,
- telefony z aplikacja WireGuard,
- inne zaufane klienty z osobnymi peerami.

Zasady bezpieczenstwa:

- kazdy klient ma osobny wpis `[Peer]`,
- kazdy klient ma osobny adres `/32`,
- kazdy klient ma osobny PSK,
- nie wspoldziel prywatnych kluczy miedzy AX3000 i telefonami.

To nie jest tylko dobra praktyka. W tym projekcie wspoldzielenie tych samych kluczy klienta miedzy AX3000 i telefonami jest traktowane jako niepoprawna konfiguracja.

Mozesz jednak utrzymac dodatkowy opcjonalny `shared profile` jako uproszczona opcje przenoszenia jednego profilu miedzy urzadzeniami. Taki profil nie jest przeznaczony do jednoczesnego uzycia przez wiele klientow.

## Najwazniejsze ryzyko

Najslabszym punktem tego wariantu nie jest sam WireGuard, tylko zbyt luzna polityka routera.

Jesli na GL.iNet zostanie wlaczony fallback, split tunnel albo zbyt szeroki ruch `LAN -> WAN`, to klient-side kill switch przestaje spelniac swoja role.

Dlatego wersja 1 powinna zostac zaakceptowana dopiero po tescie:

- tunel dziala: internet jest dostepny,
- tunel nie dziala: internet za routerem nie dziala wcale.