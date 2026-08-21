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
| Checkpoint de hardening publicado | `445eba22547a908ab854cc05b31a4c03b270d006` |
| Checkpoint de código testado | `ea096b487b889793690b9e12ac86e1f0226baa51` |
| GitHub Actions aprovado | [`32535277813`](https://github.com/rodrigomarson/Trio/actions/runs/32535277813) |
| Patch LibreTransmitter (SHA-256) | `6398f1127f4041484d555085e52d645898173305789c5e2db801762bdd030efa` |
| Patch Base64 (SHA-256) | `dd9713a66c242173f2693eee2687e24909ef9a1503047d2183eced5fb493566c` |

O ponteiro do submódulo permanece exatamente no commit oficial. O delta é
transportado por `ci_scripts/libre_brasil.patch.b64` e aplicado pelo script
pós-clone, inclusive no Xcode Cloud.

Os commits remotos `4d7d964e8`, `31ee8ef81` e `1f82c07f4`, encontrados durante
a consolidação, foram preservados. Eles registram a primeira fronteira do
provedor, habilitam o workflow de testes na branch e alinham a build 18.
O commit concorrente `d7bb54df8`, que hospeda os testes do LibreTransmitter no
alvo funcional `TrioTests`, também foi preservado integralmente.

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
- Restauração do alvo real `LibreTransmitterTests`, que havia sido removido do
  projeto em 2021 embora o esquema compartilhado ainda o referenciasse.
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
Xcode.

No GitHub Actions, a execução diagnóstica
[`32533739713`](https://github.com/rodrigomarson/Trio/actions/runs/32533739713)
compilou o patch no workspace completo do Trio e aprovou 123 testes em 19
suítes. O passo específico do LibreTransmitter revelou que o esquema apontava
para um bundle de testes inexistente no `project.pbxproj`; portanto, aqueles
testes não chegaram a executar.

A correção restaura o produto `.xctest`, a fonte, as fases de build, a
dependência do framework e as configurações do alvo, e executa a mesma fonte no
host estável `TrioTests`. A execução final
[`32535277813`](https://github.com/rodrigomarson/Trio/actions/runs/32535277813),
sobre `ea096b487`, terminou com sucesso: 16 testes XCTest do LibreTransmitter,
zero falhas, e 123 testes do Trio em 19 suítes, também sem falhas. O workflow
confirmou nominalmente os testes de classificação brasileira e privacidade do
diagnóstico; o log final não contém marcador de falha.

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

1. Executar a build 18 no Xcode Cloud, sem afrouxar os gates de privacidade ou
   segurança.
2. Instalar pelo TestFlight e validar com um sensor reservado a desenvolvimento:
   detecção correta, duas leituras NFC, diagnóstico sanitizado e erro explícito
   de provedor indisponível.
3. Manter LibreLink e um glicosímetro disponíveis durante todo o teste.
4. Integrar a próxima camada somente quando existir um backend que satisfaça o
   contrato e os critérios de licença, origem, autorização e teste em dispositivo.
