# Post-deployment test plan - WireGuard v1

## Cel

Ten plan testow ma potwierdzic, ze wersja 1 dziala zgodnie z ustaleniami:

- tunel WireGuard zestawia sie poprawnie,
- serwer obsluguje `phone-test-1` i opcjonalny `cloud-test-1`,
- ruch wychodzi przez publiczny IP AWS w Irlandii,
- kill switch po stronie serwera wymusza tryb fail-closed,
- kill switch po stronie klienta blokuje wyjscie poza VPN,
- traceroute nie pokazuje dalszych hopow tam, gdzie oczekujemy,
- instancja daje sie wygodnie uruchamiac i zatrzymywac z AWS Console na telefonie.
- opcjonalny residential proxy daje sie zapisac, wlaczyc, wylaczyc i usunac bez zmian w peerach WireGuard.
- opcjonalny relay UDP da sie zweryfikowac bez zgadywania, czy problemem jest timeout czy leak.

## Zakres testow

Testy obejmuja:

1. gotowosc instancji po starcie,
2. poprawnosc konfiguracji WireGuard,
3. widoczne IP wyjsciowe dla `phone-test-1`,
4. dodatkowego klienta testowego,
5. zachowanie traceroute,
6. podstawowe zachowanie kill switcha po stronie serwera,
7. podstawowe zachowanie kill switcha po stronie klienta,
8. operacyjne start i stop instancji.
9. operacyjne przelaczanie trybu egress.
10. opcjonalna weryfikacje relay UDP.

## Test 1 - gotowosc instancji po starcie

Cel: potwierdzic, ze po uruchomieniu EC2 wszystko wstaje automatycznie.

Kroki:

1. Uruchom instancje z AWS Console albo AWS Console Mobile App.
2. Poczekaj na `Running` i zaliczone `Status checks`.
3. Jesli chcesz dodatkowej diagnostyki bez logowania do instancji, odczytaj `Get system log` w AWS Console.

Oczekiwany wynik:

- instancja przechodzi `Status checks`,
- bootstrap nie konczy sie oczywistym bledem w logu systemowym,
- dalsze testy klienta przechodza poprawnie.

## Test 2 - publiczny adres IP

Cel: potwierdzic, ze ruch klienta wychodzi przez AWS.

Kroki:

1. Przygotuj profil `phone-test-1` wedlug [wireguard-peer-layout.md](../architecture/wireguard-peer-layout.md).
2. Uzupelnij brakujace klucze i endpoint.
3. Zaimportuj profil do aplikacji WireGuard na telefonie.
4. Zestaw tunel na telefonie.
5. Otworz strone typu `https://ifconfig.me` albo `https://icanhazip.com` na telefonie.

Oczekiwany wynik:

- publiczny adres IP nie jest lokalnym adresem klienta,
- geolokalizacja odpowiada Irlandii albo lokalizacji przypisanej do AWS region,
- widoczny jest adres AWS.

## Test 3 - dodatkowy klient testowy

Cel: potwierdzic, ze ten sam serwer obsluguje tez drugi niezalezny peer testowy.

Kroki:

1. Przygotuj osobny peer `cloud-test-1` wedlug [wireguard-peer-layout.md](../architecture/wireguard-peer-layout.md).
2. Zaimportuj odpowiadajacy mu plik `.conf` do klienta chmurowego.
3. Zestaw tunel na `cloud-test-1`, gdy `phone-test-1` pozostaje aktywny albo nieaktywny.
4. Sprawdz publiczny IP `cloud-test-1`.

Oczekiwany wynik:

- `cloud-test-1` laczy sie do tego samego Elastic IP i portu `51820/UDP`,
- `cloud-test-1` dostaje swoj osobny peer i nie koliduje z `phone-test-1`,
- widoczny publiczny IP nadal jest adresem AWS.

## Test 4 - traceroute

Cel: sprawdzic ograniczenie widocznosci hopow.

Kroki na Windows:

```powershell
tracert 1.1.1.1
```

Kroki na Linux lub macOS:

```bash
traceroute 1.1.1.1
```

Oczekiwany wynik:

- czesc hopow za EC2 nie jest ujawniana i pojawiaja sie `*`,
- lokalny adres klienta nie jest widoczny jako adres wyjsciowy,
- nie oczekujemy calkowitej niewidzialnosci calej trasy w kazdym przypadku.

## Test 5 - kill switch po stronie serwera

Cel: upewnic sie, ze routing jest fail-closed.

Kroki:

1. Zestaw tunel WireGuard.
2. Potwierdz dzialajacy ruch do internetu.
3. Zatrzymaj i uruchom ponownie instancje z AWS Console.
4. W czasie, gdy instancja jest zatrzymana, sprobuj wykonac ruch z klienta.

Oczekiwany wynik:

- ruch klienta przez tunel przestaje dzialac,
- nie ma niekontrolowanego fallbacku przez zwykla sciezke tunelowa na serwerze,
- ruch nie przechodzi, dopoki instancja nie zostanie ponownie uruchomiona.

Uwaga:

- to potwierdza kill switch po stronie EC2,
- nie potwierdza jeszcze kill switcha po stronie samego urzadzenia klienckiego.

## Test 6 - kill switch po stronie klienta

Cel: upewnic sie, ze urzadzenie nie wraca do lokalnego internetu po zerwaniu tunelu.

Kroki:

1. Wdroz klient-side kill switch zgodnie z [client-side-kill-switch-guide.md](../guides/client-side-kill-switch-guide.md).
2. Zestaw tunel WireGuard na kliencie testowym i potwierdz dzialajacy ruch do internetu.
3. Wylacz tunel WireGuard na kliencie testowym, bez zmiany jego podstawowego uplinku.
4. Sprobuj otworzyc dowolna strone albo wykonac probe polaczenia do internetu z klienta testowego.

Oczekiwany wynik:

- ruch do internetu jest blokowany,
- lokalne IP podstawowego uplinku klienta nie staje sie widoczne jako awaryjna sciezka wyjsciowa,
- po ponownym zestawieniu tunelu ruch wraca.

## Test 7 - restart i ponowny start instancji

Cel: sprawdzic latwa obsluge i trwalosc konfiguracji.

Kroki:

1. Zatrzymaj instancje z poziomu aplikacji AWS na telefonie.
2. Uruchom ja ponownie po chwili.
3. Sprawdz, czy Elastic IP pozostal ten sam.
4. Zestaw tunel ponownie bez zmian w konfiguracji klienta.

Oczekiwany wynik:

- instancja startuje bez recznej rekonfiguracji,
- Elastic IP pozostaje ten sam,
- WireGuard i firewall uruchamiaja sie automatycznie,
- klient laczy sie ponownie bez edycji profilu.

## Test 8 - podstawowa diagnostyka bez logowania do EC2

Jesli cos nie dziala, sprawdz kolejno:

1. `Instance state` i `Status checks` w AWS Console.
2. `Get system log` w AWS Console.
3. Poprawnosc `Elastic IP` i security group.
4. Poprawnosc konfiguracji klienta WireGuard.
5. Czy klient-side kill switch nie blokuje rowniez samego zestawienia tunelu.
6. Jesli uzywasz przelacznika w AWS Console, czy `Metadata options` maja wlaczone `Allow tags in metadata`.

## Test 9 - wlaczanie i wylaczanie residential proxy

Cel: upewnic sie, ze tryb egress da sie przelaczac bez naruszania konfiguracji peerow.

Kroki:

1. Skonfiguruj profil residential proxy na instancji poleceniem `wireguard-egress configure ...`.
2. Jesli uzywasz synchronizacji z AWS Console, ustaw tag `wireguard-egress-mode=residential-proxy`. W przeciwnym razie uruchom `wireguard-egress enable`.
3. Z poziomu klienta otworz strone typu `https://ifconfig.me`.
4. Zanotuj widoczny adres IP.
5. Zmien tag na `wireguard-egress-mode=direct` albo uruchom `wireguard-egress disable` i ponow test.
6. Jesli chcesz usunac zapisany profil, uruchom `wireguard-egress remove`.

Oczekiwany wynik:

- po `enable` ruch HTTP i HTTPS wychodzi przez adres residential proxy,
- ruch, ktory nie umie przejsc przez upstream proxy, jest blokowany zamiast wyjsc przez AWS,
- po `disable` ruch wraca do zwyklego adresu AWS,
- po `remove` profil proxy znika, a tryb pozostaje `direct`,
- peerzy WireGuard nie wymagaja zmiany kluczy ani adresacji.

Uwaga:

- w obecnej wersji `residential-proxy` to tryb strict fail-closed,
- plain DNS po `UDP/53` moze przestac dzialac,
- przy problemach operacyjnych fallbackiem jest tryb `direct`, czyli swiadome uzycie AWS jako IP wyjsciowego.

## Test 10 - opcjonalny relay UDP

Cel: potwierdzic, ze UDP w trybie `residential-proxy` przechodzi przez relay, nie timeoutuje lokalnie na EC2 i nie wycieka bezposrednio przez AWS.

Kroki:

1. Wlacz `ENABLE_SOCKS5_UDP_SUPPORT=true` i przygotuj config relay.
2. Uruchom `wg-residential-udp-relay.service`.
3. Wykonaj checklistę z [udp-relay-ec2-checklist.md](udp-relay-ec2-checklist.md).

Oczekiwany wynik:

- relay jest aktywny,
- `WG_UDP_PROXY` i routing table `100` sa obecne,
- UDP nie timeoutuje z powodu lokalnej awarii relay,
- na uplinku EC2 nie ma bezposredniego UDP do internetu poza upstream proxy.

## Kryteria akceptacji wersji 1

Wersja 1 jest gotowa do dalszych testow, jesli:

- klient laczy sie stabilnie z EC2,
- publiczny IP klienta jest ukryty,
- `phone-test-1` i opcjonalny `cloud-test-1` moga korzystac z tego samego serwera,
- egress wychodzi przez AWS,
- po restarcie instancji konfiguracja dziala dalej,
- traceroute ogranicza widocznosc hopow,
- kill switch po stronie serwera dziala zgodnie z zalozeniem,
- kill switch po stronie klienta blokuje awaryjny powrot do lokalnego internetu.

Jesli uzywasz opcjonalnego relay UDP, dodatkowo:

- relay dziala stabilnie,
- UDP nie leakuje bezposrednio przez AWS,
- timeout da sie odroznic od leaku na podstawie obserwacji z EC2.