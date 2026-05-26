# WireGuard peer layout

## Cel

Ten dokument ustala prosty plan adresacji i nazewnictwa peerow dla jednego serwera WireGuard na AWS.

## Aktualny uklad peerow

- `phone-test-1` - pierwszy peer testowy dla telefonu - `10.44.0.2/32`
- `cloud-test-1` - drugi peer testowy dla klienta w chmurze - `10.44.0.3/32`
- `router-prod-1` - zarezerwowany peer pod finalny travel router - `10.44.0.10/32`

## Zasady

- kazdy klient WireGuard ma osobny wpis `[Peer]` na serwerze,
- kazdy klient ma osobny adres `/32`,
- kazdy klient ma osobny PSK,
- kazdy klient musi miec osobna pare kluczy WireGuard,
- szablon klienta jest generowany osobno dla kazdego peera,
- pierwszy rollout jest walidowany telefonem i opcjonalnym klientem chmurowym,
- travel router pozostaje klientem produkcyjnym dolaczanym po przejsciu testow bazowych.

## Dlaczego nie wspoldzielic kluczy

W tym projekcie nie uzywamy tych samych kluczy dla wielu klientow.

Powody:

- wiele klientow z tym samym kluczem prywatnym oznacza ten sam klucz publiczny,
- serwer traci wtedy rozroznienie peerow,
- roaming i mapowanie endpointow staja sie niejednoznaczne,
- nie da sie poprawnie rozdzielic adresacji i konfiguracji per klient,
- wyciek jednego klucza kompromituje od razu wszystkich klientow.

Zeby uproscic operacje, wspoldzielimy:

- ten sam serwer WireGuard,
- ten sam `Endpoint`,
- ten sam port `51820/UDP`,
- ten sam schemat konfiguracji.

Nie wspoldzielimy:

- prywatnych kluczy klientow,
- publicznych kluczy klientow,
- adresow klientow `/32`,
- wpisow `[Peer]`.

## Opcjonalny shared profile

Mozna dodac opcjonalny wspoldzielony profil klienta jako wygodny tryb awaryjny lub tymczasowy.

Ten wariant:

- ma jeden dodatkowy wpis `[Peer]` na serwerze,
- ma jeden wspoldzielony plik `.conf`,
- moze byc zaimportowany do wielu urzadzen,
- nie powinien byc aktywny jednoczesnie na wielu klientach.

To jest tylko opcja pomocnicza, a nie docelowy model pracy.

Ograniczenie jest twarde:

- jesli kilka urzadzen uzyje tego samego shared profile naraz, beda nadpisywac endpoint tego samego peera,
- taki profil nadaje sie do scenariusza: jeden aktywny klient w danej chwili.

## Format definicji peerow

W bootstrapie i `user-data` peerzy sa definiowani przez zmienna `PEER_DEFINITIONS`.

Format jednego wpisu:

```text
nazwa|public_key|address_cidr|dns
```

Wiele wpisow oddziela srednik `;`.

Przyklad:

```text
phone-test-1|PHONE_TEST_PUBLIC_KEY|10.44.0.2/32|1.1.1.1;cloud-test-1|CLOUD_TEST_PUBLIC_KEY|10.44.0.3/32|1.1.1.1
```

## Jak to dziala po bootstrapie

Po stronie serwera:

- `wg0.conf` zawiera wiele sekcji `[Peer]`,
- PSK dla peerow sa zapisywane w `/etc/wireguard/peers/`,
- szablony klientow sa zapisywane w `/root/wireguard-clients/`.

Po stronie klientow:

- `phone-test-1` dostaje swoj osobny plik `.conf`,
- `cloud-test-1` dostaje swoj osobny plik `.conf`,
- finalny router produkcyjny dostaje swoj osobny plik `.conf`,
- wszystkie klienty lacza sie do tego samego Elastic IP i portu `51820/UDP`.

## Ograniczenie operacyjne

Poniewaz wersja 1 unika SSM i SSH w zwyklej obsludze, najprostszy model jest taki:

- planujesz peerow z gory,
- umieszczasz ich w `PEER_DEFINITIONS` przed wdrozeniem,
- jesli pozniej dodajesz nowego peera, aktualizujesz `user-data` lub bootstrap i wykonujesz kontrolowana rekonfiguracje.