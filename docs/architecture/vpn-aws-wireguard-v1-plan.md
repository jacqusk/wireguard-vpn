# VPN na AWS z WireGuard - ustalenia dla wersji 1

## Cel

Celem wersji 1 jest uruchomienie prostego, prywatnego serwera VPN na AWS, opartego o WireGuard na EC2, z publicznym adresem IP AWS jako adresem wyjściowym.

Priorytety na teraz:

- anonimowość rozumiana praktycznie jako ukrycie lokalnego IP klienta,
- pełny kill switch,
- ukrywanie korzystania z klienta VPN dla urzadzenia podlaczonego za klientem,
- prosta obsluga i kontrola z telefonu,
- mozliwosc latwego uruchamiania i zatrzymywania instancji dla ograniczenia kosztow.

## Co budujemy w wersji 1

Budujemy pojedyncza instancje EC2 w regionie Frankfurt, z uruchomionym WireGuard.

Zalozenia techniczne:

- jedna instancja EC2,
- jeden region AWS: Frankfurt,
- pierwszy rollout walidujemy peerem `phone-test-1`,
- opcjonalnie drugi peer testowy to `cloud-test-1`,
- travel router pozostaje krokiem finalnym po przejsciu testow bazowych,
- publiczny egress: adres IP AWS,
- pojedynczy tunel WireGuard,
- brak residential proxy w wersji 1,
- mozliwosc latwego startu i stopu instancji na zadanie.

## Jak rozumiemy anonimowosc w wersji 1

Wersja 1 nie daje silnej anonimowosci w sensie ukrycia faktu, ze ruch wychodzi z chmury. Strony docelowe moga rozpoznac IP AWS jako datacenter IP.

Na obecnym etapie anonimowosc oznacza:

- ukrycie lokalnego IP klienta,
- brak wycieku ruchu poza tunel przy awarii,
- mozliwosc pracy tak, aby urzadzenie za klientem nie musialo miec zainstalowanej wlasnej aplikacji VPN,
- ograniczenie widocznosci sciezki routingu dla polecen traceroute i tracert po stronie klienta.

## Architektura wersji 1

Przeplyw ruchu:

1. Urzadzenie klienckie laczy sie tunelem WireGuard do EC2.
2. EC2 staje sie punktem wyjscia do internetu.
3. Ruch wychodzacy widoczny na zewnatrz ma adres IP AWS.
4. Kill switch blokuje kazdy ruch, ktory nie powinien wyjsc poza tunel.

Elementy architektury:

- EC2 w regionie Frankfurt,
- Elastic IP przypisany do instancji,
- WireGuard jako publiczny punkt wejscia,
- reguly firewalla wymuszajace fail-closed,
- automatyczny start WireGuard po uruchomieniu instancji,
- automatyczne ladowanie reguł kill switch po uruchomieniu instancji,
- wdrozenie przez EC2 user data bez potrzeby codziennego dostepu administracyjnego,
- klient-side kill switch na urzadzeniu dostepowym.

## Kill switch

Kill switch jest wymagany od pierwszej wersji.

Cel kill switcha:

- jesli tunel lub routing przestanie dzialac, ruch nie moze wyjsc przypadkowo poza oczekiwana sciezke,
- lokalne IP klienta nie moze zostac ujawnione wskutek awarii tunelu,
- serwer powinien pracowac w trybie fail-closed.

W praktyce oznacza to:

- scisle reguly firewalla na EC2,
- brak niekontrolowanego fallbacku na zwykly routing publiczny,
- automatyczne odtworzenie zasad po restarcie instancji,
- blokade ruchu na samym kliencie, jesli tunel WireGuard przestanie byc aktywny.

Aktualna decyzja:

- kill switch ma dzialac po stronie EC2,
- kill switch ma dzialac rowniez po stronie klienta.

## Ukrywanie sciezki traceroute

Chcemy, aby polecenia traceroute i tracert po stronie klienta nie pokazywaly dalszej sciezki routingu, tylko znaki `*` tam, gdzie to mozliwe.

To nie jest specjalna funkcja WireGuard, tylko efekt odpowiedniej polityki firewalla na serwerze.

Podejscie:

- blokowanie odpowiedzi typu ICMP Time Exceeded wracajacych do klienta VPN,
- pozostawienie ostroznosci przy szerszym filtrowaniu ICMP, zeby nie zepsuc diagnostyki i MTU,
- testy po zestawieniu tunelu z uzyciem Windows `tracert`.

Efekt oczekiwany:

- klient nie widzi hopow za serwerem EC2,
- lokalne IP klienta pozostaje ukryte,
- widoczne pozostaje publiczne IP AWS jako punkt wyjscia.

## Obsluga i kontrola

Obsluga ma byc mozliwie prosta i dostepna z telefonu.

Model operacyjny:

- serwer wdrazamy raz,
- konfiguracja WireGuard i firewalla ma byc trwala,
- po uruchomieniu instancji wszystko ma wstawac automatycznie,
- na co dzien serwer ma byc uruchamiany i zatrzymywany z poziomu AWS.

Do zarzadzania chcemy uzywac interfejsu AWS, najlepiej z telefonu.

Wniosek:

- codzienna obsluga ma opierac sie na AWS Console,
- do podstawowego sterowania nadaje sie aplikacja mobilna AWS Console Mobile App,
- aplikacja ma wystarczyc do startu, stopu, restartu i sprawdzania statusu instancji,
- serwer ma byc traktowany jak prosty appliance uruchamiany i zatrzymywany na zadanie.

## SSM vs SSH

SSM i SSH to dwa rozne sposoby dostepu administracyjnego do instancji.

SSH:

- klasyczne logowanie na serwer przez port 22,
- wymaga otwartego portu SSH albo ograniczenia go do konkretnego IP,
- uzywa kluczy SSH,
- jest proste i powszechnie znane,
- zwieksza powierzchnie ekspozycji uslugi administracyjnej do internetu.

SSM:

- to AWS Systems Manager Session Manager,
- nie wymaga wystawiania portu 22 do internetu,
- dostep odbywa sie przez mechanizmy AWS,
- kontrola dostepu opiera sie o IAM,
- zwykle jest bezpieczniejszy i czystszy operacyjnie niz SSH.

Na co dzien nie planujemy regularnego logowania administracyjnego. Wybrany model operacyjny dla wersji 1 nie zaklada korzystania ani z SSM, ani z SSH w standardowej obsludze.

Praktyczny wybor dla wersji 1:

- brak codziennego uzycia SSM,
- brak otwartego SSH,
- wdrozenie i rekonfiguracja przez EC2 user data,
- start i stop przez AWS Console Mobile App,
- w razie bledu preferowana sciezka to poprawa bootstrapu i ponowne utworzenie lub restart instancji, zamiast logowania na serwer.

## Region i skala

Ustalony start:

- region AWS: Frankfurt,
- jedna instancja EC2,
- `phone-test-1` jako pierwszy peer testowy,
- opcjonalny `cloud-test-1` jako drugi peer testowy,
- travel router dolaczany dopiero po bazowym acceptance deploymencie,
- wersja testowa, z mozliwoscia zmiany regionu w przyszlosci.

## Koszty i operacje

Serwer ma byc uruchamiany i zatrzymywany na zadanie, zeby ograniczac koszty.

Praktyczne zalozenia:

- compute ma byc ograniczane przez zatrzymywanie instancji,
- konfiguracja musi przetrwac restart i ponowny start,
- Elastic IP powinien pozostac staly,
- trzeba pamietac, ze zatrzymanie instancji nie zawsze zeruje wszystkie koszty, bo nadal moze pozostac koszt dysku i w niektorych przypadkach adresu IP.

## Wersja 2

W wersji 2 planujemy dodanie residential proxy nad AWS.

Wtedy:

- AWS przestaje byc warstwa publicznej tozsamosci,
- AWS pozostaje prywatnym punktem wejsciowym i warstwa kontroli,
- publiczny adres widoczny przez serwisy docelowe pochodzi z residential proxy.

Aktualny krok przejsciowy:

- bootstrap i user-data potrafia zapisac profil residential proxy,
- na instancji dostepny jest helper `wireguard-egress` do `configure`, `enable`, `disable`, `remove` i `status`,
- tryb `direct` pozostaje domyslny,
- tryb `residential-proxy` jest celowo odwracalny bez zmian w peerach WireGuard,
- obecna implementacja traktuje `residential-proxy` jako tryb strict fail-closed: jesli ruch nie da sie wypchnac przez upstream proxy, jest blokowany zamiast wyjsc przez AWS,
- jesli cos przestaje dzialac, przełączasz egress z powrotem na `direct` i swiadomie uzywasz AWS jako IP wyjsciowego,
- dla pelnego ruchu pracy, Zooma i UDP docelowo nadal lepszy jest upstream tunnel-based provider.

## Rzeczy do ustalenia pozniej

- czy wdrozenie pozostaje przy EC2 user data, czy pozniej przechodzimy do IaC,
- jakie konkretne reguly firewalla wdrozymy dla traceroute i kill switcha,
- kiedy przechodzimy do wersji 2 z residential proxy.

## Aktualna decyzja robocza

Na start realizujemy wersje 1:

- WireGuard na EC2,
- region Frankfurt,
- jedna instancja,
- `phone-test-1` jako pierwszy klient testowy,
- opcjonalny `cloud-test-1` jako drugi klient testowy,
- travel router jako finalny klient produkcyjny po przejsciu testow bazowych,
- publiczny adres AWS jako egress,
- kill switch po stronie EC2 jako wymog,
- kill switch po stronie klienta jako wymog,
- ukrywanie hopow traceroute tam, gdzie to mozliwe,
- sterowanie instancja przez AWS Console i telefon,
- wdrozenie bez SSM i bez SSH w zwyklej obsludze,
- nacisk na prostote uruchamiania, zatrzymywania i dalszego rozwoju do wersji 2.

## Powiazane pliki projektu

- [aws-console-deployment-checklist.md](../deployment/aws-console-deployment-checklist.md) - checklista wdrozenia i obslugi przez AWS Console,
- [bootstrap-wireguard-ec2.sh](../../scripts/bootstrap/bootstrap-wireguard-ec2.sh) - skrypt instalacji i konfiguracji WireGuard na EC2,
- [apply-vpn-firewall.sh](../../scripts/firewall/apply-vpn-firewall.sh) - reguly firewalla dla kill switcha, NAT i ukrywania hopow traceroute.
- [wireguard-client-single-device.conf.template](../../config/wireguard/wireguard-client-single-device.conf.template) - szablon konfiguracji jednego klienta WireGuard,
- [ec2-user-data-wireguard-bootstrap.sh](../../scripts/bootstrap/ec2-user-data-wireguard-bootstrap.sh) - wariant bootstrapu do wklejenia w EC2 user data,
- [post-deployment-test-plan.md](../testing/post-deployment-test-plan.md) - minimalny plan testow po wdrozeniu,
- [client-side-kill-switch-guide.md](../guides/client-side-kill-switch-guide.md) - opis wymagan i wariantow wdrozenia kill switcha po stronie klienta,
- [travel-router-wireguard-guide.md](../guides/travel-router-wireguard-guide.md) - ogolna sciezka wdrozenia klienta na travel routerze,
- [gl-inet-wireguard-guide.md](../guides/gl-inet-wireguard-guide.md) - konkretna sciezka wdrozenia dla routera GL.iNet AX3000,
- [wireguard-peer-layout.md](wireguard-peer-layout.md) - plan peerow dla `phone-test-1`, `cloud-test-1` i finalnego routera.