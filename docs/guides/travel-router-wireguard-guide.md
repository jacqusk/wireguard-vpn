# Travel router WireGuard guide

## Cel

Ten dokument opisuje konkretna sciezke dla klienta WireGuard uruchomionego na travel routerze lub malej bramce sieciowej.

W tej architekturze:

- EC2 na AWS jest serwerem WireGuard,
- travel router jest jedynym klientem WireGuard,
- urzadzenia podpiete do routera nie musza miec wlasnej aplikacji VPN,
- kill switch na routerze blokuje zwykly ruch WAN, jesli tunel przestanie dzialac.

## Rekomendowany typ urzadzenia

Najbardziej praktyczny wariant dla wersji 1:

- travel router z natywna obsluga WireGuard,
- preferowany GL.iNet albo sprzet zgodny z OpenWrt,
- lokalny interfejs administracyjny dostepny z telefonu lub laptopa,
- mozliwosc ustawienia firewall rules i polityki routingu.

Powod wyboru:

- prostsza obsluga niz reczna konfiguracja laptopa,
- urzadzenia za routerem nie potrzebuja klienta VPN,
- kill switch mozna wdrozyc centralnie na bramce,
- dobrze pasuje do zalozenia ukrywania faktu uzycia klienta VPN dla urzadzenia koncowego.

Dla obecnej wersji projektu wybrana sciezka wykonawcza to GL.iNet AX3000. Szczegoly sa opisane w [gl-inet-wireguard-guide.md](gl-inet-wireguard-guide.md).

## Topologia

Przeplyw ruchu:

1. Travel router laczy sie do internetu przez lokalny uplink Wi-Fi albo Ethernet.
2. Travel router zestawia tunel WireGuard do EC2 w AWS.
3. Urzadzenie koncowe laczy sie tylko z travel routerem.
4. Caly ruch urzadzenia koncowego przechodzi przez router i dalej przez tunel do AWS.
5. Jesli tunel padnie, router blokuje wyjscie do internetu.

## Zasada kill switch na routerze

Kill switch na routerze powinien realizowac trzy zasady:

1. Urzadzenia w LAN maja prawo wychodzic tylko przez interfejs WireGuard.
2. Router ma prawo wychodzic przez WAN tylko do endpointu WireGuard na AWS.
3. Ruch z LAN bezposrednio na WAN jest zablokowany.

To daje efekt:

- tunel dziala: internet jest dostepny,
- tunel nie dziala: urzadzenia za routerem nie maja internetu,
- lokalny adres sieci, do ktorej podpiety jest router, nie wycieka jako adres wyjsciowy.

## Najprostszy model operacyjny

Zeby uproscic kill switch i uniezaleznic sie od DNS podczas zestawiania tunelu:

- uzywaj Elastic IP AWS jako `Endpoint` w konfiguracji WireGuard,
- nie uzywaj nazwy DNS dla endpointu w wersji 1,
- utrzymuj staly port `51820/UDP`.

To upraszcza reguly routera, bo mozesz dopuscic tylko jeden konkretny cel WAN: `AWS_ELASTIC_IP:51820/UDP`.

## Minimalna konfiguracja routera

Na routerze skonfiguruj:

1. Interfejs WireGuard z kluczem prywatnym klienta.
2. Peer wskazujacy na Elastic IP instancji AWS.
3. `AllowedIPs` ustawione na `0.0.0.0/0`, jesli caly ruch ma isc przez tunel.
4. `PersistentKeepalive = 25`.
5. Lokalna siec LAN lub Wi-Fi dla urzadzen koncowych.

Zrodlo konfiguracji:

- możesz uzyc [wireguard-client-single-device.conf.template](../../config/wireguard/wireguard-client-single-device.conf.template) jako wzorca,
- albo szablonu wygenerowanego na EC2 w `/root/wireguard-client.conf`.

## Minimalne reguly kill switch

Logika regul jest wazniejsza niz konkretna skladnia, bo zalezy od firmware routera.

Potrzebne sa co najmniej takie zasady:

1. Zezwol routerowi na polaczenie WAN do `AWS_ELASTIC_IP` po `UDP 51820`.
2. Zezwol ruchowi z LAN do interfejsu WireGuard.
3. Zezwol na ruch powrotny zwiazany z aktywnym tunelem.
4. Zablokuj forwarding z LAN bezposrednio do WAN.
5. Ogranicz panel administracyjny routera tylko do LAN.

Jesli firmware to wspiera, polityka domyslna powinna byc taka:

- `LAN -> WAN`: reject,
- `LAN -> WG`: allow,
- `Router -> AWS endpoint UDP 51820`: allow.

## Co sprawdzic przy wyborze routera

Router musi wspierac:

- klienta WireGuard,
- statyczne reguly firewalla,
- mozliwosc blokady ruchu WAN,
- latwy restart tunelu,
- stabilna prace jako mala bramka.

Najbardziej praktycznie:

- GL.iNet jest dobrym kandydatem na start,
- OpenWrt daje najwieksza kontrole,
- unikaj sprzetu, ktory ma tylko prosty przycisk VPN bez realnych regul firewalla.

## Jak to bedzie dzialac operacyjnie

Codzienny tryb pracy:

1. Uruchamiasz EC2 z AWS Console Mobile App.
2. Travel router zestawia tunel do AWS.
3. Podlaczasz urzadzenie do routera.
4. Korzystasz z internetu przez AWS IP.
5. Zatrzymujesz EC2, gdy chcesz ograniczyc koszty.

Skutek zatrzymania EC2:

- tunel znika,
- kill switch na routerze blokuje internet dla urzadzen za routerem,
- nic nie wraca awaryjnie przez zwykly uplink lokalny.

## Otwarta decyzja techniczna

Zostaje jeszcze jedna konkretna decyzja:

- jaki model travel routera wybierasz.

Po wyborze modelu mozna przygotowac juz konfiguracje praktycznie pod jego interfejs:

- GL.iNet UI,
- OpenWrt LuCI,
- albo konfiguracje z plikow i konkretnych regul firewalla.

Aktualny wybor roboczy:

- GL.iNet AX3000 jako najprostszy wariant do wdrozenia w wersji 1.