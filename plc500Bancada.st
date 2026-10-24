// ============================================================================
//  Programa da bancada PLC500 (o mesmo que está em plc500Bancada.project),
//  organizado como numa máquina de verdade. Explicação: README.md
//
//  Cada bloco começa com "//#### TIPO Nome" (o tipo de objeto a criar no CODESYS:
//  DUT, GVL, PERSISTENT = Persistent Variables, FB, FUN, PRG). Nos FB/FUN/PRG,
//  o que vem antes de "//---- código" é a parte de CIMA do editor (declaração)
//  e o resto é a parte de BAIXO (código).
// ============================================================================

//#### DUT E_Estado
// Estados da máquina. Os números são os mesmos que o coletor já lê em GVLColeta.status.
{attribute 'qualified_only'}
TYPE E_Estado :
(
    EXECUTANDO := 1,
    PARADA     := 2,
    MANUTENCAO := 4
) UINT;
END_TYPE

//#### DUT E_Evento
// Tipos de evento gravados no diário (GVL_Memoria).
{attribute 'qualified_only'}
TYPE E_Evento :
(
    LIGOU        := 1,   // o CLP ligou (ou voltou de uma queda de energia / Download)
    MUDOU_ESTADO := 2,   // apertaram um botão e o estado mudou
    PECA         := 3    // terminou uma peça (um giro completo do servo)
) UINT;
END_TYPE

//#### GVL GVL_Config
// Constantes do programa: mudar aqui muda em todo lugar.
VAR_GLOBAL CONSTANT
    TAMANHO_DIARIO : UINT := 1000;   // quantos eventos o diário guarda (os mais antigos são sobrescritos)
END_VAR

//#### GVL GVL_Maquina
// Sinais internos da máquina: as partes do programa conversam por aqui.
// NÃO são lembrados ao desligar (para isso existe a GVL_Memoria).
VAR_GLOBAL
    // ---- entradas já tratadas (PRG_Entradas)
    apertouExecutar   : BOOL;   // TRUE por 1 ciclo quando aperta o botão da DI1
    apertouParar      : BOOL;   // DI2
    apertouManutencao : BOOL;   // DI3
    dtMs              : UDINT;  // milissegundos desde o ciclo anterior

    // ---- situação da máquina (PRG_Maquina)
    estado        : E_Estado := E_Estado.PARADA;   // a máquina sempre liga PARADA (segurança)
    mudouEstado   : BOOL;       // TRUE por 1 ciclo quando o estado muda
    terminouPeca  : BOOL;       // TRUE por 1 ciclo quando completa uma peça
    anguloServo   : REAL;       // 0 a 180 graus
    servoOk       : BOOL;       // TRUE = PWM funcionando

    // ---- ajustes (com o Login ativo: digite o valor novo e aperte Ctrl+F7)
    tempoGiro     : REAL := 1.0;     // segundos por peça (um giro completo 0° -> 180° -> 0°)
    freqServo     : DWORD := 100;    // Hz do PWM. 50 = padrão de servo; 100 = movimento mais fino

    // ---- acertar o relógio do CLP: digite a hora de AGORA em UTC (Brasília + 3 h),
    //      ex: DT#2026-10-24-18:30:00, e aperte Ctrl+F7. Ele acerta e volta a ficar vazio.
    acertarRelogio : DT;
END_VAR

//#### PERSISTENT GVL_Memoria
// MEMÓRIA INTERNA: tudo aqui sobrevive a desligar o CLP, a queda de energia e a Download.
// (PERSISTENT RETAIN: o PLC500 guarda numa área de 256 kB protegida pelos supercapacitores)
//
// Regras para não perder o que já está guardado:
//  - variável nova: acrescente sempre NO FIM da lista;
//  - não renomeie nem mude o tipo de uma variável que já existe;
//  - para zerar tudo: Online > Reset origem (apaga a memória) - só se quiser mesmo.
VAR_GLOBAL PERSISTENT RETAIN
    // ---- totais que nunca zeram: se ninguém leu por um tempo, a diferença mostra o que aconteceu
    pecasTotal   : UDINT;   // peças desde sempre
    msExecutando : ULINT;   // tempo total em cada estado, em milissegundos
    msParada     : ULINT;
    msManutencao : ULINT;
    vezesLigou   : UDINT;   // quantas vezes o CLP ligou

    // ---- diário: os últimos TAMANHO_DIARIO eventos, cada um com número e hora do próprio CLP.
    // O evento número N fica na posição N MOD TAMANHO_DIARIO; diarioSeq é o número do último.
    diarioSeq      : UDINT;
    diarioNumero   : ARRAY[0..GVL_Config.TAMANHO_DIARIO - 1] OF UDINT;   // número do evento (0 = gravando)
    diarioInstante : ARRAY[0..GVL_Config.TAMANHO_DIARIO - 1] OF ULINT;   // ms desde 1970 (UTC), relógio do CLP
    diarioEvento   : ARRAY[0..GVL_Config.TAMANHO_DIARIO - 1] OF UINT;    // E_Evento
    diarioEstado   : ARRAY[0..GVL_Config.TAMANHO_DIARIO - 1] OF UINT;    // E_Estado no momento
    diarioPecas    : ARRAY[0..GVL_Config.TAMANHO_DIARIO - 1] OF UDINT;   // pecasTotal no momento
END_VAR

//#### GVL GVLColeta
// O que o coletor lê por OPC UA (marcada na Symbol Configuration).
// Os nomes antigos continuam iguais; os novos vêm da memória interna.
VAR_GLOBAL
    status        : UINT;        // 1=executando 2=parada 4=manutenção
    statusTexto   : STRING(20);  // o mesmo estado em texto
    emManutencao  : BOOL;
    cicloAtivo    : BOOL;
    pecas         : UDINT;       // total de peças (agora nunca zera: vem da memória interna)
    opNumero      : UDINT;
    motivoParada  : UINT;
    rpmSpindle    : UINT;
    temperatura   : REAL;
    emergencia    : BOOL;
    anguloServo   : REAL;        // posição do servo em graus (0 a 180)

    // ---- novos: memória interna
    segExecutando : UDINT;       // tempo total executando, em segundos (nunca zera)
    segParada     : UDINT;
    segManutencao : UDINT;
    vezesLigou    : UDINT;       // quantas vezes o CLP ligou
    relogioClp    : ULINT;       // hora do CLP em ms desde 1970 (UTC): o coletor compara com a dele
    diarioSeq     : UDINT;       // número do último evento do diário
END_VAR

//#### FB FB_Botao
// Botão com filtro: ignora trepidação e avisa uma vez por aperto.
FUNCTION_BLOCK FB_Botao
VAR_INPUT
    entrada : BOOL;               // a entrada digital (ex: DI1)
    filtro  : TIME := T#50MS;     // tem que ficar apertado pelo menos isso
END_VAR
VAR_OUTPUT
    apertou : BOOL;               // TRUE por 1 ciclo no momento do aperto
END_VAR
VAR
    tempoFiltro : TON;
    borda       : R_TRIG;
END_VAR
//---- código
tempoFiltro(IN := entrada, PT := filtro);
borda(CLK := tempoFiltro.Q);
apertou := borda.Q;

//#### FB FB_Servo
// Servo na DO1 (PWM1): gira 0° -> 180° -> 0° em curva suave ou fica parado num ângulo.
FUNCTION_BLOCK FB_Servo
VAR_INPUT
    girar        : BOOL;           // TRUE = gira sem parar; FALSE = fica em anguloParado
    anguloParado : REAL;           // 0 a 180
    tempoGiro    : REAL := 1.0;    // segundos por giro completo (mínimo 0,3)
    frequencia   : DWORD := 100;   // Hz do PWM
    dtMs         : UDINT;          // milissegundos desde o ciclo anterior
END_VAR
VAR_OUTPUT
    angulo       : REAL;           // ângulo atual
    giroCompleto : BOOL;           // TRUE por 1 ciclo ao voltar ao 0°
    ok           : BOOL;           // TRUE = PWM funcionando
END_VAR
VAR
    pwm  : IoDrvGPIO.PWM1;         // bloco da WEG que gera o PWM na DO1
    fase : REAL;                   // posição dentro do giro: 0 a 2*PI
    duty : WORD;                   // largura do pulso, em milésimos do período
END_VAR
VAR CONSTANT
    DOIS_PI : REAL := 6.2831853;
END_VAR
//---- código
giroCompleto := FALSE;

IF girar THEN
    fase := fase + UDINT_TO_REAL(dtMs) / 1000.0 * DOIS_PI / MAX(tempoGiro, 0.3);
    IF fase >= DOIS_PI THEN
        fase := fase - DOIS_PI;
        giroCompleto := TRUE;
    END_IF
    angulo := 90.0 - 90.0 * COS(fase);           // acelera saindo das pontas, freia chegando
ELSE
    angulo := LIMIT(0.0, anguloParado, 180.0);
    fase := ACOS(1.0 - angulo / 90.0);           // ao voltar a girar, parte daqui sem pulo
END_IF

// pulso de 1 ms (0°) a 2 ms (180°): duty (0..1000) = pulso em ms x frequência em Hz
duty := REAL_TO_WORD((1.0 + angulo / 180.0) * DWORD_TO_REAL(frequencia));
pwm(EN := TRUE, Frequency := frequencia, DutyCycle := duty, ENO => ok);

//#### FUN RegistrarEvento UDINT
// Grava um evento no diário da memória interna, com a hora do relógio do CLP.
// Devolve o número do evento.
FUNCTION RegistrarEvento : UDINT
VAR_INPUT
    evento : E_Evento;
END_VAR
VAR
    posicao : UINT;
    agora   : ULINT;       // ms desde 1970 (UTC)
END_VAR
//---- código
SysTimeRtc.SysTimeRtcHighResGet(agora);   // relógio do CLP (biblioteca SysTimeRtc)

GVL_Memoria.diarioSeq := GVL_Memoria.diarioSeq + 1;
posicao := UDINT_TO_UINT(GVL_Memoria.diarioSeq MOD GVL_Config.TAMANHO_DIARIO);

GVL_Memoria.diarioNumero[posicao]   := 0;   // "gravando": quem ler agora sabe que ainda não vale
GVL_Memoria.diarioInstante[posicao] := agora;
GVL_Memoria.diarioEvento[posicao]   := evento;
GVL_Memoria.diarioEstado[posicao]   := GVL_Maquina.estado;
GVL_Memoria.diarioPecas[posicao]    := GVL_Memoria.pecasTotal;
GVL_Memoria.diarioNumero[posicao]   := GVL_Memoria.diarioSeq;   // pronto

RegistrarEvento := GVL_Memoria.diarioSeq;

//#### PRG PRG_Entradas
// 1º passo do ciclo: lê as entradas físicas e mede o tempo do ciclo.
PROGRAM PRG_Entradas
VAR
    botaoExecutar   : FB_Botao;
    botaoParar      : FB_Botao;
    botaoManutencao : FB_Botao;
    agora           : TIME;
    anterior        : TIME;
    primeiraVez     : BOOL := TRUE;
END_VAR
//---- código
botaoExecutar(entrada := DI1);
botaoParar(entrada := DI2);
botaoManutencao(entrada := DI3);
GVL_Maquina.apertouExecutar   := botaoExecutar.apertou;
GVL_Maquina.apertouParar      := botaoParar.apertou;
GVL_Maquina.apertouManutencao := botaoManutencao.apertou;

agora := TIME();
IF primeiraVez THEN
    GVL_Maquina.dtMs := 0;
    primeiraVez := FALSE;
ELSE
    GVL_Maquina.dtMs := MIN(TIME_TO_UDINT(agora - anterior), 100);   // pausa longa não vira salto
END_IF
anterior := agora;

//#### PRG PRG_Maquina
// 2º passo: a lógica da máquina (estado pelos botões e o servo que "produz" as peças).
PROGRAM PRG_Maquina
VAR
    servo      : FB_Servo;
    estadoNovo : E_Estado;
END_VAR
//---- código
// ---- o último botão apertado vira o estado (manutenção tem prioridade)
estadoNovo := GVL_Maquina.estado;
IF GVL_Maquina.apertouManutencao THEN
    estadoNovo := E_Estado.MANUTENCAO;
ELSIF GVL_Maquina.apertouParar THEN
    estadoNovo := E_Estado.PARADA;
ELSIF GVL_Maquina.apertouExecutar THEN
    estadoNovo := E_Estado.EXECUTANDO;
END_IF
GVL_Maquina.mudouEstado := (estadoNovo <> GVL_Maquina.estado);
GVL_Maquina.estado := estadoNovo;

// ---- servo: executando gira; parada descansa em 0°; manutenção vai para o centro (90°)
servo(
    girar        := (GVL_Maquina.estado = E_Estado.EXECUTANDO),
    anguloParado := SEL(GVL_Maquina.estado = E_Estado.MANUTENCAO, 0.0, 90.0),
    tempoGiro    := GVL_Maquina.tempoGiro,
    frequencia   := GVL_Maquina.freqServo,
    dtMs         := GVL_Maquina.dtMs);
GVL_Maquina.anguloServo  := servo.angulo;
GVL_Maquina.servoOk      := servo.ok;
GVL_Maquina.terminouPeca := servo.giroCompleto;   // um giro completo = uma peça

//#### PRG PRG_Memoria
// 3º passo: atualiza a memória interna (totais e diário). Ver GVL_Memoria.
PROGRAM PRG_Memoria
VAR
    primeiraVez : BOOL := TRUE;   // volta a TRUE toda vez que o CLP liga ou recebe Download
END_VAR
//---- código
IF primeiraVez THEN
    primeiraVez := FALSE;
    GVL_Memoria.vezesLigou := GVL_Memoria.vezesLigou + 1;
    RegistrarEvento(E_Evento.LIGOU);
END_IF

// ---- tempo em cada estado
CASE GVL_Maquina.estado OF
    E_Estado.EXECUTANDO: GVL_Memoria.msExecutando := GVL_Memoria.msExecutando + GVL_Maquina.dtMs;
    E_Estado.PARADA:     GVL_Memoria.msParada     := GVL_Memoria.msParada + GVL_Maquina.dtMs;
    E_Estado.MANUTENCAO: GVL_Memoria.msManutencao := GVL_Memoria.msManutencao + GVL_Maquina.dtMs;
END_CASE

// ---- eventos
IF GVL_Maquina.terminouPeca THEN
    GVL_Memoria.pecasTotal := GVL_Memoria.pecasTotal + 1;
    RegistrarEvento(E_Evento.PECA);
END_IF
IF GVL_Maquina.mudouEstado THEN
    RegistrarEvento(E_Evento.MUDOU_ESTADO);
END_IF

//#### PRG PRG_Saidas
// 4º passo: liga as saídas físicas. DO4 executando (pisca), DO5 parada, DO6 manutenção.
// (a DO1 é o PWM do servo: não escreva DO1 := ... em lugar nenhum)
PROGRAM PRG_Saidas
VAR
    pisca : TON;
    aceso : BOOL;
END_VAR
//---- código
pisca(IN := NOT pisca.Q, PT := T#500MS);
IF pisca.Q THEN
    aceso := NOT aceso;
END_IF
DO4 := (GVL_Maquina.estado = E_Estado.EXECUTANDO) AND aceso;
DO5 := (GVL_Maquina.estado = E_Estado.PARADA);
DO6 := (GVL_Maquina.estado = E_Estado.MANUTENCAO);

//#### PRG PRG_Coleta
// 5º passo: copia para a GVLColeta o que o coletor (Raspberry) lê por OPC UA.
PROGRAM PRG_Coleta
VAR
    agora    : ULINT;
    novaHora : ULINT;
END_VAR
//---- código
GVLColeta.status := GVL_Maquina.estado;
CASE GVL_Maquina.estado OF
    E_Estado.EXECUTANDO: GVLColeta.statusTexto := 'EXECUTANDO';
    E_Estado.PARADA:     GVLColeta.statusTexto := 'PARADA';
    E_Estado.MANUTENCAO: GVLColeta.statusTexto := 'MANUTENCAO';
END_CASE
GVLColeta.cicloAtivo   := (GVL_Maquina.estado = E_Estado.EXECUTANDO);
GVLColeta.emManutencao := (GVL_Maquina.estado = E_Estado.MANUTENCAO);
GVLColeta.anguloServo  := GVL_Maquina.anguloServo;

GVLColeta.pecas         := GVL_Memoria.pecasTotal;
GVLColeta.segExecutando := ULINT_TO_UDINT(GVL_Memoria.msExecutando / 1000);
GVLColeta.segParada     := ULINT_TO_UDINT(GVL_Memoria.msParada / 1000);
GVLColeta.segManutencao := ULINT_TO_UDINT(GVL_Memoria.msManutencao / 1000);
GVLColeta.vezesLigou    := GVL_Memoria.vezesLigou;
GVLColeta.diarioSeq     := GVL_Memoria.diarioSeq;

// ---- relógio do CLP (biblioteca SysTimeRtc): acerta se pediram, depois entrega a hora
IF GVL_Maquina.acertarRelogio > DT#2000-01-01-00:00:00 THEN
    novaHora := DT_TO_ULINT(GVL_Maquina.acertarRelogio) * 1000;
    SysTimeRtc.SysTimeRtcHighResSet(novaHora);
    GVL_Maquina.acertarRelogio := DT#1970-01-01-00:00:00;
END_IF
SysTimeRtc.SysTimeRtcHighResGet(agora);
GVLColeta.relogioClp := agora;

//#### PRG PLC_PRG
// Chamado pela MainTask a cada 10 ms. Só define a ORDEM das partes:
// lê entradas -> decide -> guarda na memória -> liga saídas -> entrega para o coletor.
PROGRAM PLC_PRG
VAR
END_VAR
//---- código
PRG_Entradas();
PRG_Maquina();
PRG_Memoria();
PRG_Saidas();
PRG_Coleta();
