# Build de desenvolvimento do Trio para o Libre Brasil

## Identificação da build

| Item | Valor |
| --- | --- |
| Base instalada | Branch `rodrigo-v0.8.4` no commit `55d984f11704e0fd516c7d6a7f27671d038d995a` |
| Versão da base instalada | `0.8.4` (build `1`) |
| Esta versão de desenvolvimento | `0.8.4.17` |
| Equipe de desenvolvimento Apple | `6KLJLLTX3K` |
| Identificador do bundle | `org.nightscout.6KLJLLTX3K.trio` |
| Scheme compartilhado | `Trio` |
| Distribuição | Xcode Cloud para TestFlight |

Esta branch representa a primeira etapa diagnóstica segura para o suporte direto ao
FreeStyle Libre 2 Plus brasileiro. Ela ainda não converte os frames do sensor
brasileiro em valores de glicose. Seu objetivo é identificar o sensor de forma
confiável, preservar os dados NFC capturados e evitar o envio de um comando europeu
de streaming ainda não validado para esse sensor.

A branch parte da mesma fonte utilizada na versão instalada no iPhone, sem incorporar
as alterações amplas da branch oficial `dev`. Também preserva os estados observados
dos submódulos G7SensorKit (`4d0780d`), MedtrumKit (`7a3cb27`) e OmnipodKit
(`4d25449`), além do LibreTransmitter oficial em `20f6d0e`.

## Limites das evidências

O classificador inicial é baseado em capturas do Libre 2 Plus brasileiro com patch
info `2B 0A 3A 08 1F E1` e família de produto 3. Investigações da comunidade também
relatam que o caminho oficial do LibreLink reconhece esses sensores, enquanto os
algoritmos europeus atuais de conexão direta os rejeitam. Consulte as investigações
relacionadas do xDrip
[#3545](https://github.com/NightscoutFoundation/xDrip/discussions/3545) e
[#4028](https://github.com/NightscoutFoundation/xDrip/discussions/4028).

Essas observações identificam uma família de protocolo distinta, mas não estabelecem
um algoritmo seguro para ativação do streaming ou descriptografia. Por isso, esta
build captura evidências NFC somente para leitura antes da inclusão de um driver para
o protocolo brasileiro.

## Alterações realizadas

- Reconhece valores de patch info iniciados por `0x2B` como Libre 2 Plus Brasil.
- Classifica o protocolo do sensor antes de enviar qualquer comando NFC de streaming.
- Mantém inalterado o fluxo existente de pareamento e descriptografia do Libre 2
  europeu.
- Bloqueia o comando europeu `A1/1E` de ativação do streaming para a variante
  brasileira.
- Lê sequencialmente todos os 43 blocos NFC, evitando uma condição de corrida que
  poderia produzir uma captura parcial da FRAM durante o pareamento.
- Armazena um diagnóstico versionado contendo UID, patch info, tipo do sensor, FRAM
  criptografada, data e hora da captura e indicação de tentativa de envio do comando
  de streaming.
- Exibe explicitamente o sensor brasileiro detectado na tela de configuração e
  oferece uma ação de compartilhamento do diagnóstico em JSON.
- Aplica a alteração do LibreTransmitter a partir do próprio repositório do Trio, para
  que o Mac local e o Xcode Cloud utilizem o mesmo código-fonte sem exigir um segundo
  fork.

## Estrutura do repositório

O repositório do Trio continua fixando o commit oficial do submódulo
LibreTransmitter. As alterações brasileiras são armazenadas em
`ci_scripts/libre_brasil.patch.b64`. Tanto o Xcode Cloud quanto o desenvolvimento
local decodificam e aplicam esse patch por meio de
`ci_scripts/apply_libre_brasil_patch.sh`.

O Xcode Cloud detecta automaticamente o arquivo `ci_scripts/ci_post_clone.sh` depois
de clonar o repositório. Para um clone local, execute:

```sh
git clone --recurse-submodules --branch rodrigo-v0.8.4-libre-brasil-dev \
  https://github.com/rodrigomarson/Trio.git
cd Trio
./scripts/apply_libre_brasil_patch.sh
open Trio.xcworkspace
```

O script do patch é idempotente: executá-lo novamente depois de uma aplicação
concluída é seguro.

## Validação local no Mac

1. No Xcode, selecione o scheme compartilhado `Trio` e um iPhone como destino.
2. Confirme que a assinatura utiliza a equipe `6KLJLLTX3K` e que a assinatura
   automática está habilitada.
3. Resolva os pacotes Swift. Nesta branch, a dependência Swift-JWT utiliza HTTPS.
4. Compile o scheme `Trio` e depois execute os testes unitários do LibreTransmitter.
5. Gere um archive local se for necessário diagnosticar alterações de assinatura ou
   entitlements antes de iniciar uma build no Xcode Cloud.

O identificador do app e os entitlements existentes foram preservados
intencionalmente. Assim, a build de desenvolvimento utiliza a mesma configuração já
adotada pelo Trio para Apple Developer, HealthKit, NFC, Bluetooth, modos em segundo
plano, notificações push, App Groups e Keychain.

## Xcode Cloud e TestFlight

Utilize o workflow existente do Trio, selecionando esta branch como origem e o scheme
compartilhado `Trio`. O script pós-clone aplica o patch do LibreTransmitter antes da
resolução dos pacotes e da compilação. Configure o workflow para gerar um archive de
iOS e distribuir uma build concluída com sucesso para o grupo interno desejado do
TestFlight.

A versão do projeto é `0.8.4.17` e o número local da build começa em `17`. O Xcode
Cloud ainda precisa utilizar um número de build superior a todos os números já
enviados para a mesma versão do app. Se o App Store Connect informar que o número da
build está duplicado, defina no workflow o próximo número acima do maior valor atual
do TestFlight e gere uma nova build.

## Procedimento de teste do sensor

Utilize um sensor destinado ao desenvolvimento e não tome decisões de tratamento com
base nesta build experimental.

1. Instale a build pelo TestFlight.
2. No Trio, abra a configuração do CGM, selecione Libre e escolha o caminho de conexão
   direta.
3. Faça a leitura NFC do Libre 2 Plus brasileiro.
4. Confirme que o Trio informa **Libre 2 Plus Brazil** em vez de
   **No Sensor Detected**.
5. Confirme que a tela informa que o comando europeu de streaming não foi enviado.
6. Compartilhe o diagnóstico JSON e armazene-o junto com a versão do app e o modelo
   do sensor.

Resultado esperado para o sensor brasileiro: detecção e exportação do diagnóstico,
sem tentativa de ativar o streaming europeu. Resultado esperado para o teste de
regressão com o Libre 2 europeu: o caminho existente de pareamento direto continua
disponível.

## Próxima etapa do protocolo

A próxima etapa de implementação somente deve começar depois da análise do
diagnóstico brasileiro. Ela deverá adicionar um adaptador separado para o protocolo
brasileiro, atrás do roteador de capacidades existente, com fixtures e testes para
análise do patch, tratamento dos frames NFC, ativação do streaming, descriptografia,
extração da glicose e transições de estado do sensor. O adaptador europeu deverá
permanecer inalterado e coberto por testes de regressão.
