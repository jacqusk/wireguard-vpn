# Residential Proxy Cutover

## Cel

Ten runbook opisuje bezpieczne przejscie z aktualnie dzialajacego rollouta `direct` do trybu `residential-proxy` bez zmiany peerow WireGuard.

## Aktualny punkt startowy

- aktywny endpoint WireGuard: `108.132.84.168:51820`,
- aktywna instancja: `i-0a993b61208bd0d54`,
- peer `phone-test-1` zostal juz potwierdzony w realnym tescie,
- aktualny tryb egress: `direct`,
- `ENABLE_SOCKS5_UDP_SUPPORT=false`,
- standard operacyjny nadal zaklada brak SSH i brak SSM.

## Wazne ograniczenie operacyjne

Repo wspiera dwa sposoby wejscia w `residential-proxy`:

1. przez bootstrap przy starcie instancji, jesli ustawisz `EGRESS_MODE=residential-proxy` oraz rzeczywiste zmienne `RESIDENTIAL_PROXY_*`,
2. przez jednorazowe polecenie `wireguard-egress configure ...` uruchomione juz na EC2.

Przy obecnym modelu `no-SSH/no-SSM` druga droga nie jest praktycznie dostepna. To oznacza, ze dla tego deploymentu najczystsza sciezka do proxy to nowy replacement rollout z proxy wpisanym w user data.

## Co musisz miec przed cutoverem

Minimalnie:

1. `RESIDENTIAL_PROXY_HOST`
2. `RESIDENTIAL_PROXY_PORT`
3. `RESIDENTIAL_PROXY_TYPE`
4. `RESIDENTIAL_PROXY_USERNAME` jesli wymagany
5. `RESIDENTIAL_PROXY_PASSWORD` jesli wymagany

Do etapu UDP dodatkowo:

1. potwierdzenie, ze provider wspiera `SOCKS5 UDP ASSOCIATE`,
2. decyzje, czy wlaczasz tylko TCP-only proxy, czy od razu tez UDP relay,
3. plan dla `sing-box` i `/etc/sing-box/wg-residential-udp-relay.json`.

## Zalecana kolejnosc

Najpierw zrob cutover tylko dla TCP. UDP zostaw jako osobny etap po potwierdzeniu, ze sam upstream proxy jest stabilny.

### Etap A - TCP-only residential proxy

Ustaw na potrzeby replacement rollout:

```bash
EGRESS_MODE="residential-proxy"
ENABLE_SOCKS5_UDP_SUPPORT="false"
ENABLE_AWS_CONSOLE_EGRESS_SWITCH="false"
RESIDENTIAL_PROXY_TYPE="socks5"
RESIDENTIAL_PROXY_HOST="REPLACE_ME"
RESIDENTIAL_PROXY_PORT="REPLACE_ME"
RESIDENTIAL_PROXY_USERNAME="REPLACE_ME"
RESIDENTIAL_PROXY_PASSWORD="REPLACE_ME"
```

Praktyczna sekwencja:

1. Wypelnij lokalne pliki `generated/proxy-cutover-preflight.local.env` i `generated/proxy-cutover-user-data.local.env`.
2. Wygeneruj nowy launcher user-data poleceniem:

```bash
bash scripts/health/render-first-rollout-user-data.sh \
	--validation-mode none \
	--preflight generated/proxy-cutover-preflight.local.env \
	--user-data generated/proxy-cutover-user-data.local.env \
	--output generated/ec2-user-data-proxy-cutover.local.sh
```

3. Uruchom nowa instancje replacement z tym user data.
4. Poczekaj na `WireGuard bootstrap completed.` w `Get system log`.
5. Potwierdz, ze peer `phone-test-1` nie wymaga zmiany kluczy ani adresacji.
6. Przepnij Elastic IP dopiero po pozytywnej walidacji nowej instancji.
7. Z telefonu sprawdz IP na `https://ifconfig.me`.

Oczekiwany wynik:

- WireGuard nadal zestawia tunel na tym samym profilu klienta,
- HTTP/HTTPS wychodzi przez upstream residential proxy,
- ruch, ktory nie przechodzi przez upstream proxy, pozostaje fail-closed zamiast wychodzic przez AWS.

### Etap B - opcjonalny UDP relay

Dopiero po stabilnym TCP-only:

```bash
ENABLE_SOCKS5_UDP_SUPPORT="true"
```

Do tego etapu potrzebujesz jeszcze:

1. `RESIDENTIAL_PROXY_TYPE=socks5`,
2. `sing-box` dostepnego na EC2,
3. pliku `/etc/sing-box/wg-residential-udp-relay.json`,
4. checklisty z `docs/optional-features/sing-box-ubuntu-24.04-udp-relay-setup.md`,
5. walidacji z `docs/testing/udp-relay-ec2-checklist.md`.

## Uwaga o obecnych helperach walidacyjnych

`scripts/health/validate-first-rollout-inputs.sh` jest nadal nastawiony na rollout `direct-only`. Dlatego renderer dla proxy cutovera powinien byc uruchamiany z `--validation-mode none`, bo inaczej z definicji oczekuje:

- `EGRESS_MODE="direct"`,
- `ENABLE_SOCKS5_UDP_SUPPORT="false"`.

Do proxy cutovera traktuj render user-data i sam bootstrap jako glowny punkt walidacji, a nie ten konkretny validator pierwszego rollouta.

## Rollback

Jesli cos nie dziala, rollback powinien byc natychmiastowy i prosty:

1. zostawiasz peerow WireGuard bez zmian,
2. wracasz do instancji lub rollouta z `EGRESS_MODE="direct"`,
3. przepinasz Elastic IP z powrotem dopiero po potwierdzeniu zdrowego stanu.

## Brakujace dane do realnego startu

Do faktycznego cutovera proxy nadal brakuje tylko danych upstream proxy. Bez nich runbook jest gotowy, ale samej zmiany nie da sie jeszcze bezpiecznie wykonac.