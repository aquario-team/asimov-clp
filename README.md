# asimov-clp — programa do PLC500 da bancada

Programa CODESYS do CLP WEG PLC500 da bancada, organizado como numa máquina real e com memória interna.
O coletor que lê este CLP fica no repositório [asimov](https://github.com/aquario-team/asimov).

O programa do PLC500 da bancada (3 botões, LEDs, servo que "produz" peças) está pronto aqui:

| Arquivo | O que é |
|---|---|
| `plc500Bancada.project` | projeto do CODESYS pronto: é só abrir, compilar e mandar para o CLP |
| `plc500Bancada.st` | o mesmo programa em texto (para ler, comparar versões ou colar à mão) |

Foi montado a partir do seu último projeto e compilado no CODESYS V3.5 SP22 Patch 4 com **0 erros e 0 avisos**.
O que ele faz é o mesmo de antes (botões DI1/DI2/DI3, LEDs DO4/DO5/DO6, servo suave na DO1, um giro = uma peça).
As novidades são a **organização em partes** e a **memória interna**: o CLP passa a lembrar dos totais e de um
diário de eventos mesmo desligado, então o que acontecer enquanto o Raspberry está fora não se perde.

## 1. Mandar para o CLP (jeito rápido)

1. Abra `plc500Bancada.project` no CODESYS (se perguntar sobre versão do projeto/biblioteca, aceite manter).
2. **Build → Build** (F11): tem que terminar com **0 erros**.
3. Ligue o notebook na rede do CLP (ETH1, `192.168.1.10`) e, em **Device → Communication Settings**, escolha o PLC500 (Scan Network).
4. **Online → Login** (Alt+F8). Ele vai avisar que o programa é diferente: escolha **Login with download**.
5. **Debug → Start** (F5). O LED RUN fica verde e a DO5 (parada) acende.
6. Confira pelo coletor (repositório asimov): `python -m coletor --maquina plc500Bancada` (ou o botão **Coletar** na central).

> Depois que essa versão estiver no CLP, mudanças pequenas de código podem ir por **Login → Online Change**
> (não para o CLP). Mudar a lista da `GVL_Memoria` ou a tarefa exige Download.

## 2. As configurações (se precisar refazer do zero ou conferir)

Tudo isso já está feito dentro do `.project`. Serve de checklist se você criar um projeto novo:

| Onde | O que | Por quê |
|---|---|---|
| Projeto novo | Dispositivo **PLC500** (pacote WEG 1.5.0.1, firmware 1.5.0) | sem o pacote certo o CLP recusa o programa |
| **Application → Task Configuration → MainTask** | Cyclic, **Interval `t#10ms`** | 100 atualizações por segundo: servo liso e botões rápidos |
| **MainTask** | chama só o **`PLC_PRG`** | o `PLC_PRG` chama as outras partes na ordem certa |
| **Library Manager → Add Library** | **SysTimeRtc** (System) | é de onde vem o relógio do CLP (hora dos eventos) |
| **Application → Add Object → Persistent Variables** | nome **`GVL_Memoria`** | é a memória interna (seção 4) |
| **Application → Symbols** (Symbol Configuration) | marcar **`GVLColeta`** e **`GVL_Memoria`**, acesso **Read** (só leitura) | é o que aparece no OPC UA para o coletor; só leitura = ninguém de fora altera nada |
| **Device → I_Os → I/Os Parameters → DO1 / PWM1** | **Pin type = PWM** (as outras saídas ficam DO) | sem isso a DO1 é uma saída comum e o bloco `PWM1` do código não mexe o servo |
| Ligações | 24 V no V+ (pino 1) e COM (pino 2) das saídas; botões nas DI1–DI3 (PNP, COM no pino 11) | ver [docs/PLC500.md](https://github.com/aquario-team/asimov/blob/main/docs/PLC500.md) no asimov |

## 3. Como o programa está organizado

Numa máquina real ninguém escreve tudo num bloco só: cada parte tem seu lugar, e o ciclo segue sempre a mesma ordem.

```
MainTask (a cada 10 ms) -> PLC_PRG
     1. PRG_Entradas   lê os botões (com filtro) e mede o tempo do ciclo
     2. PRG_Maquina    decide o estado e move o servo (um giro = uma peça)
     3. PRG_Memoria    soma os totais e grava os eventos no diário
     4. PRG_Saidas     acende os LEDs
     5. PRG_Coleta     copia para a GVLColeta o que o coletor lê
```

| Objeto | Tipo | Para que serve |
|---|---|---|
| `E_Estado`, `E_Evento` | DUT (enumeração) | nomes no lugar de números: `E_Estado.PARADA` em vez de `2` |
| `GVL_Config` | GVL de constantes | tamanho do diário (`TAMANHO_DIARIO`) |
| `GVL_Maquina` | GVL | sinais internos e ajustes (`tempoGiro`, `freqServo`, `acertarRelogio`) |
| `GVL_Memoria` | Persistent Variables | **memória interna** (seção 4) |
| `GVLColeta` | GVL | o que o coletor lê (nomes antigos mantidos + os novos totais) |
| `FB_Botao` | bloco de função | filtro de 50 ms + "apertou" uma vez por aperto; usado 3 vezes |
| `FB_Servo` | bloco de função | curva suave e PWM da DO1 |
| `RegistrarEvento` | função | grava um evento no diário com a hora do CLP |

Bloco de função (FB) é como uma "classe": escreve uma vez e cria quantas cópias quiser (`botaoExecutar`, `botaoParar`...).
Para mudar algo, você sabe onde ir: LEDs → `PRG_Saidas`; regra de estado → `PRG_Maquina`; o que vai para o coletor → `PRG_Coleta`.

## 4. A memória interna (`GVL_Memoria`)

Variável comum volta ao valor inicial quando o CLP desliga. Variável **PERSISTENT RETAIN** não: o PLC500 guarda
numa área de **256 kB** protegida por supercapacitores (aguenta pelo menos 30 dias sem energia).

**O que sobrevive a quê:**

| Acontecimento | variável comum | RETAIN | **PERSISTENT RETAIN** (a nossa) |
|---|---|---|---|
| desligar / queda de energia | perde | mantém | **mantém** |
| Online Change | mantém | mantém | **mantém** |
| Reset quente | perde | mantém | **mantém** |
| Reset frio | perde | perde | **mantém** |
| Download (programa novo) | perde | perde | **mantém** |
| Reset origem | perde | perde | perde (é o "apagar tudo") |

**O que fica guardado:**

- **Totais que nunca zeram:** `pecasTotal`, tempo em cada estado (`msExecutando`, `msParada`, `msManutencao`) e `vezesLigou`.
  Se ninguém ler por 1 hora, na volta a diferença mostra o que aconteceu: "+120 peças, 50 min executando, 10 min parada".
- **Diário de eventos:** os últimos **1000** eventos (ligou, mudou de estado, terminou peça), cada um com
  número sequencial, **hora do relógio do CLP**, estado e total de peças naquele momento.
  O evento número N fica na posição `N MOD 1000`; `diarioSeq` é o número do último. Quando enche, sobrescreve o mais antigo.
  - Espaço: 1000 eventos × 20 bytes ≈ 20 kB dos 256 kB. Dá para subir `TAMANHO_DIARIO` para uns 10 000.
  - Quanto tempo cobre: com uma peça por segundo, 1000 eventos ≈ 16 min; com uma peça por minuto, ≈ 16 h.
    Para cobrir mais tempo, aumente `TAMANHO_DIARIO` (exige Download; o diário recomeça vazio, os totais continuam).

**O coletor recebe pela `GVLColeta`:** `pecas` (agora é o total que nunca zera), `segExecutando`, `segParada`,
`segManutencao`, `vezesLigou`, `diarioSeq` e `relogioClp`. Elas já estão em [maquinas/plc500Bancada.yaml](https://github.com/aquario-team/asimov/blob/main/maquinas/plc500Bancada.yaml) do asimov
(os tempos com `variacaoMinima: 60`, para não mandar uma mudança por segundo; `relogioClp` fica desmarcada).
O diário completo fica na `GVL_Memoria`, também liberada só para leitura no OPC UA: ler o diário e mandar
para a fila os eventos que faltaram é o próximo passo no coletor.

**Regras para não perder o que já está guardado:**

1. Variável nova na `GVL_Memoria`: acrescente **no fim** da lista.
2. Não renomeie nem mude o tipo de uma variável que já existe (o CODESYS trataria como outra e começaria do zero).
3. Para zerar tudo de propósito: **Online → Reset origin** (apaga o programa e a memória; depois faça Download de novo).

**Ver a memória funcionando:** com o Login ativo, abra `GVL_Memoria` (dois cliques) e veja os valores mudando.
Teste de verdade: aperte EXECUTAR, deixe contar algumas peças, **tire o CLP da tomada**, ligue de novo e
confira que `pecasTotal` continua de onde parou e `vezesLigou` aumentou 1.

## 5. O relógio do CLP

Os eventos do diário levam a hora do **relógio do CLP** (em UTC, milissegundos desde 1970). Na bancada ele
estava em 2024, então acerte uma vez:

1. Com o Login ativo, abra `GVL_Maquina`.
2. Em `acertarRelogio`, digite a hora de **agora em UTC** (Brasília + 3 h). Ex: são 15:30 em Brasília → `DT#2026-10-24-18:30:00`.
3. Aperte **Ctrl+F7** (Write values). O CLP acerta o relógio e o campo volta a ficar vazio.

O relógio continua andando com o CLP desligado (supercapacitores). `GVLColeta.relogioClp` mostra a hora do CLP:
o coletor pode comparar com a dele para saber se o relógio do CLP adiantou ou atrasou.

## 6. Ajustes com o CLP rodando

Com o Login ativo: digite o valor novo na coluna *Prepared value* e aperte **Ctrl+F7**.

| Variável (`GVL_Maquina`) | Padrão | Efeito |
|---|---|---|
| `tempoGiro` | 1.0 | segundos por peça (mínimo 0,3) |
| `freqServo` | 100 | Hz do PWM; se o servo zumbir ou tremer, use 50 |
| `acertarRelogio` | vazio | acerta o relógio do CLP (seção 5) |

## 7. Manter este repositório

- Editou no CODESYS: salve, feche e faça commit do `.project`. Para o histórico ficar legível, atualize também o
  `plc500Bancada.st` com o mesmo código (é o que mostra **o que mudou** num diff; o `.project` é binário).
- Os arquivos que o CODESYS gera sozinho (`*.opt`, `*.compileinfo`, `*.bootinfo`, `*.precompilecache`, `*.~u`,
  o XML de símbolos) ficam fora do git (`.gitignore`).
