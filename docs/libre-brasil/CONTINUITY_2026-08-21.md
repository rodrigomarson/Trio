# Checkpoint de continuidade — Libre Brasil — 2026-08-21

## Estado executivo

A branch `rodrigo-v0.8.4-libre-brasil-dev` contém a fronteira nativa segura do
Trio para o Libre 2 Plus brasileiro. A revisão atual identifica o perfil
observado, coleta e valida somente as duas evidências NFC Gen2 de leitura,
encaminha os dados em memória a um provedor opcional e falha de forma fechada
quando esse provedor não existe.

Isto ainda não é suporte direto completo: não há backend autorizado conectado
para ativação/autenticação Gen2, sessão BLE, processamento do stream ou
publicação de glicose. A build experimental não deve ser usada como única fonte
de CGM.

## Bases congeladas

| Componente | Referência |
| --- | --- |
| Checkpoint diagnóstico inicial | `d2c3d0eda54e6ee404b1bb1f07bc49a1dfb0c30f` |
| Trio antes deste hardening | `1f82c07f40c2cdba4e51e7aa8c72a346ee4fa745` |
| LibreTransmitter oficial | `20f6d0e171450b294b202cefa8edaf2c5e4a5150` |
| Branch de trabalho | `rodrigo-v0.8.4-libre-brasil-dev` |
| Versão / build | `0.8.4` / `18` |
| Patch LibreTransmitter (SHA-256) | `d1bd510a799409c82a0fa92b75e0b38e85b0e42cf5ba3f2f0e3817a42058582d` |
| Patch Base64 (SHA-256) | `03a8aeafb4923a91af386be9194d3ab6e5649cd93fbf4cf222a5959c7b878cfb` |

O ponteiro do submódulo permanece exatamente no commit oficial. O delta é
transportado por `ci_scripts/libre_brasil.patch.b64` e aplicado pelo script
pós-clone, inclusive no Xcode Cloud.

Os commits remotos `4d7d964e8`, `31ee8ef81` e `1f82c07f4`, encontrados durante
a consolidação, foram preservados. Eles registram a primeira fronteira do
provedor, habilitam o workflow de testes na branch e alinham a build 18.

## Entrega consolidada

- Gate regional separado do fluxo europeu, limitado ao perfil brasileiro
  observado.
- Leitura sequencial `A1/22` e `A1/20`, com comprimentos esperados de 6 e 25
  bytes e máquina de estado vazio/parcial/completo.
- Contrato limitado `Libre2VendorBridgeInput` e resultado normalizado
  `Libre2VendorBridgeResult`.
- `UnavailableLibre2VendorBridge` como padrão de produção, sempre falhando
  fechado.
- `AuthorizedLibre2ProviderAdapter` sem algoritmo proprietário e com estados
  desconhecidos normalizados para indisponível.
- Parada segura mesmo quando um backend retorna `success` ou `alreadyActive`;
  o Trio ainda não publica sucesso de pareamento.
- Diagnóstico versionado e compartilhável contendo apenas metadados, contagens,
  códigos públicos, capacidades e categorias de saída.
- UID, patch info, FRAM, desafio, respostas NFC, endereço BLE, autenticação e
  estado interno do provedor excluídos da serialização e dos logs novos.
- Leitura de FRAM europeia serializada por blocos, removendo a condição de
  corrida anterior, sem alterar o protocolo europeu.
- Testes de classificação, regressão europeia, parsing, evidência, limites do
  bridge, normalização fechada e privacidade do diagnóstico.
- Auditoria automática executada no `ci_post_clone.sh` antes da compilação.

## Evidência de validação reproduzível

Em um worktree limpo do LibreTransmitter no commit fixado:

1. o patch Base64 foi decodificado e aplicado sem intervenção;
2. a validação de marcadores seguros passou;
3. o catálogo de strings foi validado como JSON;
4. `git diff --check` passou;
5. o delta reconstruído foi idêntico byte a byte ao patch de origem;
6. uma segunda aplicação foi reconhecida como já aplicada, confirmando
   idempotência.

Também passaram a sintaxe dos três scripts shell e a verificação de que o
ponteiro do submódulo continua em `20f6d0e`. Este ambiente não possui Swift nem
Xcode; compilação, testes XCTest e archive ainda precisam ser executados pelo
Xcode Cloud ou em um Mac.

## Reavaliação dos backends em 2026-08-21

O levantamento foi repetido contra as revisões públicas mais recentes:

- [DiaBLE `e6a909c8`](https://github.com/gui-dos/DiaBLE/tree/e6a909c88faeada49f461d30834174cd95db4042)
  reconhece o Libre 2+ latino-americano, mas `Libre2Gen2` permanece vazio e
  [o fluxo BLE](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Abbott.swift)
  ainda deixa `processChallengeResponse()` e
  `createSecureStreamingSession()` como tarefas não implementadas.
- [Juggluco `11d016eb`](https://github.com/j-kaltes/Juggluco/tree/11d016eb3aeffe77e86d9522f5192e83790b5a21)
  mantém a orquestração Gen2 pública, mas as transformações `V1`/`V2` e o
  processamento de dados continuam delegados à biblioteca nativa
  `libDataProcessing.so` carregada dinamicamente.
- O repositório público `libre-sensor-ios` continua declarando somente leituras
  simuladas e não fornece ativação/autenticação Gen2 completa.

Conclusão: não foi localizado um backend iOS completo, autorizado, portátil e
com licença compatível que possa ser ligado ao Trio neste checkpoint.

## Próxima ação operacional

1. Publicar este checkpoint na branch de desenvolvimento.
2. Executar a build 18 no Xcode Cloud.
3. Corrigir qualquer incompatibilidade de compilação sem afrouxar os gates de
   privacidade ou segurança.
4. Instalar pelo TestFlight e validar com um sensor reservado a desenvolvimento:
   detecção correta, duas leituras NFC, diagnóstico sanitizado e erro explícito
   de provedor indisponível.
5. Manter LibreLink e um glicosímetro disponíveis durante todo o teste.
6. Integrar a próxima camada somente quando existir um backend que satisfaça o
   contrato e os critérios de licença, origem, autorização e teste em dispositivo.
