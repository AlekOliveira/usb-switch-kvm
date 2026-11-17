# usb-switch-kvm

Transforma um **switch USB comum** (testado com o **Ugreen CM662**) em um **KVM**:
quando você aperta o botão do switch, além do teclado e do mouse, o **monitor troca de entrada** sozinho.

Não precisa de KVM, de software do fabricante do monitor nem de nenhuma dependência: é um único script PowerShell usando APIs nativas do Windows.

## Como funciona

```
 [teclado/mouse] ──► [switch USB Ugreen] ──┬──► Desktop  (DisplayPort no monitor)
                                           └──► Notebook (HDMI no monitor)
```

1. **Detecção** – o script roda no desktop e escuta os eventos de dispositivo do Windows (`Win32_DeviceChangeEvent`, via WMI/CIM). A cada evento ele verifica se o **hub do switch** (`USB\VID_05E3&PID_0610`, chip Genesys Logic) está presente.
   - Ele vigia o **hub**, não o teclado: plugar/tirar periféricos não troca a tela, só o botão do switch.
   - Só age depois que o estado fica estável por 1 s (ignora clique duplo / botão oscilando).
2. **Troca de entrada** – usa **DDC/CI**, o padrão VESA para controlar o monitor pelo próprio cabo de vídeo, através da *Monitor Configuration API* do Windows (`dxva2.dll`). O código VCP `0x60` (Input Source) recebe:
   - `0x0F` → DisplayPort, quando o switch está no desktop
   - `0x11` → HDMI 1, quando o switch vai para o notebook

## Requisitos

- Windows 10/11 no computador que roda o script
- Monitor com **DDC/CI** habilitado no menu (testado no Samsung Odyssey G5)
- Um switch USB que apareça como hub no Windows

## Uso

```powershell
# só registra conexões/desconexões do switch (não mexe no monitor)
.\monitor-switch.ps1

# modo KVM: troca a entrada do monitor junto com o switch
.\monitor-switch.ps1 -Switch

# registra também cada dispositivo USB que entra/sai (diagnóstico)
.\monitor-switch.ps1 -Switch -Diag

# utilitários
.\monitor-switch.ps1 -Get         # mostra a entrada atual do monitor
.\monitor-switch.ps1 -Set 0x11    # força uma entrada
```

O log fica em `monitor-switch.log`, na mesma pasta do script.

Se o PowerShell bloquear o script, rode com `powershell -ExecutionPolicy Bypass -File .\monitor-switch.ps1 -Switch`.

## Adaptando para o seu setup

Por enquanto a configuração fica no topo do script:

| Variável | Padrão | O que é |
|---|---|---|
| `$DeviceIdPrefix` | `USB\VID_05E3&PID_0610\` | ID do hub do switch USB |
| `$InputDP` | `0x0F` | entrada do monitor quando o switch está neste PC |
| `$InputHDMI` | `0x11` | entrada do monitor quando o switch sai deste PC |

Para descobrir o ID do seu switch, rode com `-Diag`, aperte o botão e veja qual hub aparece e some no log.
Para descobrir os códigos de entrada do seu monitor, use `-Get` em cada entrada.

## Limitações

- O desktop não sabe para onde o switch foi: desconectar o cabo do switch ou tirá-lo da energia também faz o monitor ir para o HDMI.
- Ainda não inicia sozinho no logon (planejado).

## Roadmap

- [ ] Parâmetros de linha de comando / arquivo de configuração em vez de variáveis no script
- [ ] Instalação como tarefa agendada no logon
- [ ] Assistente para descobrir o ID do switch e as entradas do monitor
- [ ] Suporte a mais de um monitor

## Licença

MIT
