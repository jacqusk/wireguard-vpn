# AWS Console deployment checklist - WireGuard v1

## Cel

Ta checklista opisuje jednorazowe wdrozenie serwera WireGuard na EC2 oraz pozniejsza obsluge z poziomu AWS Console i telefonu.

## Zalozenia

- region startowy: Irlandia (`eu-west-1`),
- jedna instancja EC2,
- pierwszy rollout jest testowany telefonem jako osobnym peerem WireGuard,
- opcjonalnie drugi peer testowy moze byc uruchomiony w chmurze,
- travel router pozostaje finalnym krokiem produkcyjnym, a nie pierwszym klientem testowym,
- publiczny egress: adres IP AWS,
- kill switch wymagany od pierwszej wersji,
- kill switch wymagany rowniez po stronie klienta,
- brak SSM w standardowej obsludze,
- brak SSH w standardowej obsludze,
- codzienna obsluga: AWS Console Mobile App,
- opcjonalny upstream residential proxy moze byc wlaczany i wylaczany niezaleznie od peerow WireGuard.

## Co przygotowac przed wdrozeniem

1. Konto AWS z dostepem do EC2, IAM i Elastic IP.
2. Potwierdzenie, ze to jest wlasciwe docelowe konto AWS i wlasciwe docelowe repo GitHub dla tego deploymentu.
3. Aplikacje AWS Console Mobile App na telefonie.
4. Telefon z aplikacja WireGuard jako pierwszy klient testowy.
5. Opcjonalny drugi klient testowy w chmurze.
6. Pary kluczy klienta WireGuard dla `phone-test-1` i opcjonalnie `cloud-test-1`.
7. Publiczne klucze klientow do wpisania w `PEER_DEFINITIONS`.
8. Plan peerow zgodny z [wireguard-peer-layout.md](../architecture/wireguard-peer-layout.md).

Numeracja w dalszej czesci checklisty zaklada, ze pierwszy rollout jest `direct-only` i nie wlacza jeszcze `residential-proxy`, UDP relay ani travel routera.

## Preflight przed deploymentem

Przed kliknieciem `Launch instance` potwierdz:

1. To jest wlasciwe docelowe konto AWS.
2. To jest wlasciwe docelowe repo GitHub i wlasciwy branch z kodem deploymentowym.
3. Region jest zgodny z decyzja wdrozeniowa.
4. Pierwszy rollout pozostaje `direct-only`.
5. Nie wlaczasz jeszcze `residential-proxy`, UDP relay ani AWS tag-driven egress switch.
6. Masz gotowy publiczny klucz dla `phone-test-1`.
7. Jesli chcesz od razu wpisac drugi peer, masz tez gotowy publiczny klucz dla `cloud-test-1`.

Do pierwszego rollouta mozesz uzyc gotowych przykladow z repo:

- [deployment-preflight.first-rollout.example.env](../../config/examples/deployment-preflight.first-rollout.example.env)
- [peer-definitions.first-rollout.example.txt](../../config/examples/peer-definitions.first-rollout.example.txt)
- [user-data.first-rollout.example.env](../../config/examples/user-data.first-rollout.example.env)

Po uzupelnieniu swoich lokalnych kopii mozesz je sprawdzic lokalnie przed deploymentem:

```bash
bash scripts/health/validate-first-rollout-inputs.sh \
   --preflight PATH_TO_PREFLIGHT_ENV \
   --user-data PATH_TO_USER_DATA_ENV
```

Jesli chcesz wygenerowac gotowy plik do wklejenia jako `User data`, uruchom:

```bash
bash scripts/health/render-first-rollout-user-data.sh \
   --preflight PATH_TO_PREFLIGHT_ENV \
   --user-data PATH_TO_USER_DATA_ENV \
   --output generated/ec2-user-data-first-rollout.sh
```

Po wygenerowaniu wklejasz zawartosc `generated/ec2-user-data-first-rollout.sh` do pola `User data` w AWS Console.

Domyslnie helper generuje maly launcher zgodny z limitem 16 KB, ktory pobiera repo i uruchamia [bootstrap-wireguard-ec2.sh](../../scripts/bootstrap/bootstrap-wireguard-ec2.sh) na instancji.

Jesli docelowe repo GitHub ma byc prywatne, ustaw `DEPLOYMENT_SOURCE_URL` w preflight na dostepny URL do archiwum `.tar.gz`, na przyklad w S3.

## Przygotowanie kluczy klienta

Na urzadzeniu klienckim wygeneruj klucze WireGuard lokalnie. Nie generuj prywatnego klucza klienta na serwerze.

Przyklad:

```bash
wg genkey | tee client.key | wg pubkey > client.pub
```

Zachowaj:

- `client.key` tylko lokalnie,
- zawartosc `client.pub` do uzycia na EC2.

## Uruchomienie instancji EC2

1. Wejdz do AWS Console w regionie `eu-west-1`.
2. Otworz EC2 i wybierz `Launch instance`.
3. Nazwa instancji: na przyklad `wireguard-vpn-v1`.
4. AMI: Ubuntu Server 24.04 LTS.
5. Typ instancji: `t4g.nano` dla testow lub `t4g.micro`, jesli chcesz wiekszy zapas.
6. Jezeli wybierasz `t4g`, upewnij sie, ze AMI jest zgodne z ARM64.
7. Klucz SSH nie jest wymagany.
8. Siec: publiczna podsiec z publicznym IPv4.
9. Security group:
   - pozwol na UDP `51820` z internetu,
   - nie otwieraj TCP `22`.
10. Storage: co najmniej `8 GiB` gp3.
11. IAM role nie jest wymagana dla samego wariantu bez SSM, jesli nie korzystasz z innych uslug wymagajacych roli.
12. Jesli chcesz sterowac egress z poziomu tagu w AWS Console, wlacz `Allow tags in metadata` w `Metadata options`.
13. W sekcji `Advanced details` wklej [ec2-user-data-wireguard-bootstrap.sh](../../scripts/bootstrap/ec2-user-data-wireguard-bootstrap.sh) do pola `User data` po podmianie `PEER_DEFINITIONS` na faktyczne klucze klientow.
14. Uruchom instancje.

## Przypiecie Elastic IP

1. W EC2 przejdz do `Elastic IPs`.
2. Wybierz `Allocate Elastic IP address`.
3. Przypisz nowy adres do utworzonej instancji.
4. Zanotuj Elastic IP, bo bedzie uzyty jako endpoint WireGuard.

## Jednorazowa konfiguracja serwera

Wybrany wariant wdrozenia:

- automatyczny przy starcie instancji z uzyciem [ec2-user-data-wireguard-bootstrap.sh](../../scripts/bootstrap/ec2-user-data-wireguard-bootstrap.sh).

### Wariant - automatyczny przez EC2 user data

1. Otworz plik [ec2-user-data-wireguard-bootstrap.sh](../../scripts/bootstrap/ec2-user-data-wireguard-bootstrap.sh).
2. Podmien `PEER_DEFINITIONS` na rzeczywiste publiczne klucze `phone-test-1` i opcjonalnie `cloud-test-1`.
3. Dla pierwszego rolloutu zostaw `EGRESS_MODE="direct"`, `ENABLE_SOCKS5_UDP_SUPPORT="false"` i `ENABLE_AWS_CONSOLE_EGRESS_SWITCH="false"`.
4. Opcjonalnie podmien pozostale zmienne na poczatku pliku.
5. Jesli chcesz miec dodatkowy wspoldzielony profil awaryjny, ustaw `ENABLE_SHARED_PROFILE="true"` i wpisz `SHARED_CLIENT_PUBLIC_KEY`.
6. Nie wlaczaj jeszcze `residential-proxy` ani UDP relay w pierwszym rolloutcie.
7. Przy tworzeniu instancji w AWS Console rozwin sekcje `Advanced details`.
8. Wklej caly plik do pola `User data`.
9. Uruchom instancje.
10. Po pierwszym starcie sprawdz `Status checks` instancji.
11. Jesli potrzebujesz diagnostyki bez logowania, uzyj `Get system log` w AWS Console.
12. W wariancie bez SSH i bez SSM w `Get system log` szukaj bloku `-----BEGIN PRIMARY CLIENT TEMPLATE-----` do `-----END PRIMARY CLIENT TEMPLATE-----`. Ten blok zawiera gotowy szablon profilu dla `phone-test-1`, razem z `PresharedKey`, ale nadal wymaga podmiany `YOUR_ELASTIC_IP_OR_DNS` na przypisany Elastic IP i wpisania prywatnego klucza wygenerowanego lokalnie na telefonie.

### Przyklad pierwszego rollouta

Bezpieczny minimalny pierwszy rollout moze wygladac tak:

```bash
PRIMARY_CLIENT_NAME="phone-test-1"
PEER_DEFINITIONS="phone-test-1|REPLACE_WITH_PHONE_TEST_PUBLIC_KEY|10.44.0.2/32|1.1.1.1;cloud-test-1|REPLACE_WITH_CLOUD_TEST_PUBLIC_KEY|10.44.0.3/32|1.1.1.1"
EGRESS_MODE="direct"
ENABLE_SOCKS5_UDP_SUPPORT="false"
ENABLE_AWS_CONSOLE_EGRESS_SWITCH="false"
```

Jesli chcesz maksymalnie ograniczyc ryzyko pierwszego przebiegu, mozesz na start zostawic tylko jeden peer:

```bash
PRIMARY_CLIENT_NAME="phone-test-1"
PEER_DEFINITIONS="phone-test-1|REPLACE_WITH_PHONE_TEST_PUBLIC_KEY|10.44.0.2/32|1.1.1.1"
EGRESS_MODE="direct"
ENABLE_SOCKS5_UDP_SUPPORT="false"
ENABLE_AWS_CONSOLE_EGRESS_SWITCH="false"
```

## Co robi bootstrap

Skrypt:

- instaluje WireGuard i wymagane pakiety,
- wlacza IPv4 forwarding,
- wylacza IPv6, zeby ograniczyc ryzyko leakow,
- generuje klucze serwera,
- zapisuje `wg0.conf` z wieloma peerami,
- instaluje reguly firewalla z kill switchem,
- instaluje przelaczalny mechanizm egress `direct` albo `residential-proxy`,
- opcjonalnie pilnuje tagu instancji AWS i sam przelacza tryb egress,
- ustawia automatyczny start po restarcie,
- tworzy osobne szablony konfiguracji klientow.

## Weryfikacja po wdrozeniu

Na serwerze sprawdz:

```bash
sudo systemctl status wg-firewall.service
sudo systemctl status wg-quick@wg0
sudo wg show
sudo iptables -S
sudo iptables -t nat -S
```

Otworz wygenerowany plik klienta:

```bash
sudo cat /root/wireguard-client.conf
```

W pliku klienta podmien:

- `CLIENT_PRIVATE_KEY_GOES_HERE` na prywatny klucz klienta wygenerowany lokalnie,
- `YOUR_ELASTIC_IP_OR_DNS` na Elastic IP przypisany do instancji.

Dla `phone-test-1` oczekiwany adres klienta to `10.44.0.2/32`, a dla `cloud-test-1` to `10.44.0.3/32`.

Mozesz tez skorzystac z lokalnego szablonu [wireguard-client-single-device.conf.template](../../config/wireguard/wireguard-client-single-device.conf.template).

Dla pierwszego rollouta masz tez gotowe szablony per-peer:

- [phone-test-1.conf.template](../../config/wireguard/phone-test-1.conf.template)
- [cloud-test-1.conf.template](../../config/wireguard/cloud-test-1.conf.template)

Przy wariancie multi-peer szablony klientow beda rowniez wygenerowane osobno w katalogu `/root/wireguard-clients/`.

Dla pierwszego rolloutu oczekuj co najmniej pliku dla `phone-test-1`, a jesli od razu wpisales oba peery, to takze dla `cloud-test-1`.

Jesli pracujesz bez SSH i bez SSM, pobierz profil `phone-test-1` z `Get system log` w AWS Console. Szukaj bloku `-----BEGIN PRIMARY CLIENT TEMPLATE-----` do `-----END PRIMARY CLIENT TEMPLATE-----`, skopiuj go do lokalnego pliku albo bezposrednio do aplikacji WireGuard, a potem:

- podmien `CLIENT_PRIVATE_KEY_GOES_HERE` na prywatny klucz z telefonu,
- podmien `YOUR_ELASTIC_IP_OR_DNS` na Elastic IP instancji.

Jesli wlaczysz opcjonalny shared profile, serwer wygeneruje dodatkowo plik `/root/wireguard-shared-client.conf`.

Jesli przygotujesz residential proxy, na instancji bedzie tez dostepny helper `/usr/local/sbin/wireguard-egress`.

Przyklady:

```bash
sudo wireguard-egress status
sudo wireguard-egress configure --host proxy.example.net --port 1080 --type socks5 --username USER --password PASS
sudo wireguard-egress enable
sudo wireguard-egress disable
sudo wireguard-egress remove
```

Jesli wlaczysz synchronizacje z AWS Console, zmieniasz juz tylko tag instancji:

- klucz tagu: `wireguard-egress-mode` albo wartosc z `AWS_EGRESS_TAG_KEY`,
- wartosci: `direct` albo `residential-proxy`,
- timer na instancji odczytuje tag z IMDSv2 co `AWS_EGRESS_SYNC_INTERVAL_SECONDS` sekund.

To daje praktyczny model:

1. profil residential proxy konfigurujesz raz,
2. potem w AWS Console zmieniasz tylko tag,
3. instancja sama przelacza egress bez SSH i bez SSM.

Uwaga praktyczna:

- tryb `residential-proxy` w tej wersji jest strict fail-closed,
- jesli ruch nie da sie wypchnac przez upstream proxy, zostaje zablokowany zamiast wyjsc przez AWS,
- plain DNS po `UDP/53` moze w tym trybie przestac dzialac,
- jesli cos nie dziala, przelaczasz tag albo helper z powrotem na `direct` i swiadomie uzywasz AWS jako IP wyjsciowego,
- peerzy WireGuard i adresacja pozostaja takie same niezaleznie od aktywnego trybu egress.

Przed pierwszym uzyciem wdroz klient-side kill switch zgodnie z [client-side-kill-switch-guide.md](../guides/client-side-kill-switch-guide.md).

Travel router pozostaje krokiem finalnym. Gdy bazowy rollout przejdzie testy `phone-test-1` i opcjonalnie `cloud-test-1`, wtedy dokument wykonawczy dla routera to [gl-inet-wireguard-guide.md](../guides/gl-inet-wireguard-guide.md).

## Testy funkcjonalne

1. Importuj konfiguracje `phone-test-1` do aplikacji WireGuard na telefonie.
2. Jesli dodajesz `cloud-test-1`, przygotuj osobny profil dla tego klienta.
3. Zestaw tunel `phone-test-1`.
4. Sprawdz publiczny adres IP w przegladarce na telefonie.
5. Potwierdz, ze widoczny jest adres AWS z Irlandii.
6. Dopiero po sukcesie telefonu zestaw opcjonalny tunel `cloud-test-1`.
7. Uruchom `tracert` lub `traceroute` z klienta testowego i sprawdz, czy dalsze hopy sa ukrywane jako `*` tam, gdzie oczekujesz.
8. Rozlacz tunel klienta testowego i sprawdz, czy klient-side kill switch blokuje ruch poza VPN.

Pelny minimalny zestaw testow jest opisany w [post-deployment-test-plan.md](../testing/post-deployment-test-plan.md).

## Obsluga na co dzien

Do codziennej obslugi korzystaj z AWS Console Mobile App.

Typowe akcje:

1. `Start instance` - gdy chcesz korzystac z VPN.
2. `Stop instance` - gdy chcesz ograniczyc koszty.
3. `Reboot instance` - gdy potrzebny jest restart.
4. Sprawdzenie `Instance state checks` i podstawowego statusu.

## Uwagi kosztowe

- Zatrzymanie instancji ogranicza koszt compute.
- Dysk EBS nadal kosztuje.
- Elastic IP moze generowac koszt w zaleznosci od sposobu przypiecia i aktualnej polityki AWS.
- W praktyce warto zatrzymywac instancje, ale nie zakladac, ze koszt spadnie do zera.

## Decyzje do pozniejszego etapu

- kiedy przechodzimy do wersji 2 z residential proxy,
- czy przenosimy wdrozenie do automatyzacji IaC.