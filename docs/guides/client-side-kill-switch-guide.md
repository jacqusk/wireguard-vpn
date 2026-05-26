# Client-side kill switch guide

## Cel

Client-side kill switch ma zablokowac ruch internetowy na urzadzeniu dostepowym, jesli tunel WireGuard przestanie byc aktywny.

To zabezpieczenie chroni przed sytuacja, w ktorej:

- tunel VPN pada,
- klient pozostaje nadal podlaczony do lokalnej sieci,
- system automatycznie wraca do zwyklego wyjscia do internetu,
- lokalne IP klienta staje sie widoczne.

## Relacja do kill switcha po stronie EC2

Kill switch po stronie EC2 i po stronie klienta rozwiazuja dwa rozne problemy.

EC2-side kill switch:

- wymusza poprawny routing na serwerze,
- nie pozwala, aby ruch z tunelu wychodzil niekontrolowanie przez inna sciezke na EC2.

Client-side kill switch:

- blokuje sam klient przed powrotem do lokalnego internetu,
- nie pozwala, aby urzadzenie ominelo VPN po zerwaniu tunelu.

Docelowo w tym projekcie wymagane sa oba.

## Wybrany model operacyjny

Poniewaz wersja 1 ma byc obslugiwana bez SSM i bez SSH, klient-side kill switch staje sie waznym elementem ochrony prywatnosci.

W praktyce oznacza to:

- EC2 uruchamiasz i zatrzymujesz z AWS Console Mobile App,
- serwer zestawia WireGuard automatycznie po starcie,
- klient nie moze wrocic do zwyklego internetu, jesli tunel padnie.

## Jak wdrozyc client-side kill switch

Sposob wdrozenia zalezy od rodzaju urzadzenia klienckiego. W tym projekcie wybrany zostal travel router lub mini-bramka jako klient WireGuard.

### Wariant 1 - telefon lub tablet

Jesli system operacyjny wspiera tryb `Always-on VPN` i `Block connections without VPN`, to jest to najlepszy wariant dla telefonu.

Cel:

- telefon nie wysyla ruchu poza VPN,
- po rozlaczeniu tunelu polaczenia sa blokowane, a nie przechodza lokalnie.

### Wariant 2 - laptop lub desktop

Najpewniejszy model to reguly firewalla systemowego, ktore:

- pozwalaja zestawic polaczenie do endpointu WireGuard na AWS,
- pozwalaja na ruch przez interfejs VPN,
- blokuja zwykle wyjscie do internetu poza tunelem.

Na takim urzadzeniu trzeba uwazac, aby reguly:

- nie zablokowaly samego zestawienia tunelu,
- nie zablokowaly lokalnej administracji, jesli jest potrzebna,
- byly latwe do wlaczenia i wylaczenia podczas testow.

### Wariant 3 - travel router lub bramka

Jesli urzadzenie dostepowe ma jednoczesnie ukrywac fakt korzystania z VPN dla urzadzen podpietych za nim, to router lub mini-bramka jest bardzo dobrym wariantem.

W takim modelu kill switch polega na tym, ze:

- WAN nie przepuszcza zwyklego ruchu klientow poza tunelem,
- ruch downstream jest dozwolony tylko przez WireGuard,
- po zerwaniu tunelu ruch urzadzen za routerem zostaje zablokowany.

To jest wybrany wariant dla tego projektu.

Szczegoly wdrozenia sa opisane w [travel-router-wireguard-guide.md](travel-router-wireguard-guide.md).

## Co jeszcze trzeba ustalic

Zeby zamknac temat konfiguracji klienta, pozostaje juz nie wybor platformy, tylko wybor konkretnego modelu routera i jego systemu.

Najbardziej praktyczny kierunek dla wersji 1:

- GL.iNet AX3000 jako preferowany travel router z WireGuard,
- najlepiej oparty o OpenWrt lub z interfejsem zblizonym do OpenWrt,
- lokalne urzadzenia podpiete do routera po Wi-Fi albo LAN,
- kill switch realizowany regułami firewalla na routerze.

Dokument wykonawczy dla wybranego wariantu:

- [gl-inet-wireguard-guide.md](gl-inet-wireguard-guide.md).