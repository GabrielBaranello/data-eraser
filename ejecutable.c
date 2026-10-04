#include <efi.h>
#include <efilib.h>

#define ATA_CMD_SECURITY_SET_PASSWORD  0xF1

static EFI_GUID LocalAtaPassThruProtocolGuid = { 0x1d3de7f0, 0x0807, 0x424f, { 0xaa, 0x61, 0x2e, 0x3a, 0x2d, 0x3d, 0xdd, 0x9f } };
static EFI_GUID LocalRngProtocolGuid         = { 0x3152cc5c, 0xe524, 0x4e0d, { 0x85, 0x37, 0xc1, 0x92, 0xc1, 0x8b, 0x33, 0x4f } };

typedef struct _EFI_ATA_PASS_THRU_COMMAND_PACKET {
    void   *Acb;
    void   *InDataBuffer;
    void   *OutDataBuffer;
    UINT32 InTransferLength;
    UINT32 OutTransferLength;
    UINT32 Protocol;
    UINT32 Length;
    UINT64 Timeout;
} EFI_ATA_PASS_THRU_COMMAND_PACKET;

typedef struct {
    UINT8  AtaCommand;
    UINT8  AtaFeatures;
    UINT8  AtaSectorCount;
    UINT8  AtaSectorNumber;
    UINT8  AtaCylinderLow;
    UINT8  AtaCylinderHigh;
    UINT8  AtaDeviceHead;
    UINT8  AtaCommand2;
    UINT8  AtaFeatures2;
    UINT8  AtaSectorCount2;
    UINT8  AtaSectorNumber2;
    UINT8  AtaCylinderLow2;
    UINT8  AtaCylinderHigh2;
    UINT8  AtaDeviceHead2;
} EFI_ATA_COMMAND_BLOCK;

typedef struct _EFI_ATA_PASS_THRU_PROTOCOL {
    void *PassThru;
    EFI_STATUS (EFIAPI *GetNextDevice) (struct _EFI_ATA_PASS_THRU_PROTOCOL *This, UINT16 *Port, UINT16 *PortMultiplierPort);
} EFI_ATA_PASS_THRU_PROTOCOL;

typedef struct _EFI_RNG_PROTOCOL {
    EFI_STATUS (EFIAPI *GetRNG) (struct _EFI_RNG_PROTOCOL *This, void *RngAlgorithm, UINTN RngValueLength, UINT8 *RngValue);
} EFI_RNG_PROTOCOL;

typedef struct {
    UINT16 ControlWord;
    UINT8  Password[32]; // Longitud fija según estándar ATA
    UINT8  Reserved[478];
} ATA_SECURITY_PASSWORD_BUFFER;

EFI_STATUS
EFIAPI
efi_main (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
    EFI_STATUS                     Status;
    EFI_ATA_PASS_THRU_PROTOCOL     *AtaPassThru;
    EFI_RNG_PROTOCOL               *RngProtocol;
    UINT16                         Port;
    UINT16                         PortMultiplierPort;
    EFI_ATA_PASS_THRU_COMMAND_PACKET Packet;
    EFI_ATA_COMMAND_BLOCK          Acb;
    ATA_SECURITY_PASSWORD_BUFFER   Buffer;
    EFI_INPUT_KEY                  Key;

    InitializeLib(ImageHandle, SystemTable);

    // 1. Advertencia y petición de confirmación explícita
    Print(L"!!! ADVERTENCIA CRITICA !!!\n");
    Print(L"Esta accion bloqueara el almacenamiento local de forma IRREVERSIBLE.\n");
    Print(L"Presione la tecla [ENTER] para confirmar el bloqueo inmediato u otra tecla para cancelar.\n\n");

    // Vaciar el búfer de entrada de teclado previo
    uefi_call_wrapper(SystemTable->ConIn->Reset, 2, SystemTable->ConIn, FALSE);

    // Esperar por la pulsación de una tecla
    UINTN EventIndex;
    uefi_call_wrapper(SystemTable->BootServices->WaitForEvent, 3, 1, &SystemTable->ConIn->WaitForKey, &EventIndex);
    Status = uefi_call_wrapper(SystemTable->ConIn->ReadKeyStroke, 2, SystemTable->ConIn, &Key);

    // Verificar si el usuario presionó la tecla ENTER (Carriage Return)
    if (EFI_ERROR(Status) || Key.UnicodeChar != 0x000D) {
        Print(L"Operacion cancelada por el usuario. Saliendo...\n");
        return EFI_SUCCESS;
    }

    Print(L"Procesando comando de aislamiento...\n");

    // 2. Obtener el hardware RNG para entropía binaria pura sin mapeo legible
    Status = uefi_call_wrapper(SystemTable->BootServices->LocateProtocol, 3, &LocalRngProtocolGuid, NULL, (void **)&RngProtocol);
    if (EFI_ERROR(Status)) {
        Print(L"Fallo de Hardware: RNG no disponible.\n");
        return Status;
    }

    SystemTable->BootServices->SetMem(&Buffer, sizeof(Buffer), 0);
    // ControlWord 0x0001 asigna el nivel máximo de bloqueo (Maximum Security Mode)
    Buffer.ControlWord = 0x0001; 

    // Almacenar bytes puramente aleatorios directamente en el espacio de la contraseña
    Status = uefi_call_wrapper(RngProtocol->GetRNG, 4, RngProtocol, NULL, 32, Buffer.Password);
    if (EFI_ERROR(Status)) {
        Print(L"Fallo al generar entropia.\n");
        return Status;
    }

    // 3. Localizar e invocar interfaz ATA Passthrough
    Status = uefi_call_wrapper(SystemTable->BootServices->LocateProtocol, 3, &LocalAtaPassThruProtocolGuid, NULL, (void **)&AtaPassThru);
    if (EFI_ERROR(Status)) {
        Print(L"Error: Interfaz de bus ATA ausente.\n");
        return Status;
    }

    Port = 0xFFFF;
    PortMultiplierPort = 0xFFFF;
    Status = uefi_call_wrapper(AtaPassThru->GetNextDevice, 3, AtaPassThru, &Port, &PortMultiplierPort);
    if (EFI_ERROR(Status)) {
        Print(L"No se detectaron unidades SATA activas.\n");
        return Status;
    }

    // 4. Preparar el bloque de comandos ATA
    SystemTable->BootServices->SetMem(&Acb, sizeof(Acb), 0);
    Acb.AtaCommand = ATA_CMD_SECURITY_SET_PASSWORD;

    SystemTable->BootServices->SetMem(&Packet, sizeof(Packet), 0);
    Packet.Acb = &Acb;
    Packet.InDataBuffer = &Buffer;
    Packet.InTransferLength = sizeof(Buffer);
    Packet.Protocol = 1; // Escritura por protocolo PIO Data-Out
    Packet.Length = 0;
    Packet.Timeout = 30000000; // 3 segundos de margen

    // 5. Enviar comando de bloqueo al bus
    Status = uefi_call_wrapper(AtaPassThru->PassThru, 5, AtaPassThru, Port, PortMultiplierPort, &Packet, NULL);
    
    // Limpieza agresiva de memoria del búfer de la contraseña en RAM inmediatamente después del intento
    SystemTable->BootServices->SetMem(&Buffer, sizeof(Buffer), 0);

    if (EFI_ERROR(Status)) {
        Print(L"Comando rechazado (Controlador bloqueado/Freeze Lock activo).\n");
        Print(L"Reiniciando el sistema en 3 segundos...\n");
        SystemTable->BootServices->Stall(3000000);
    } else {
        Print(L"Operacion ejecutada correctamente. Reiniciando hardware...\n");
    }

    // 6. Forzar reinicio inmediato en frío (Cold Reset)
    uefi_call_wrapper(SystemTable->RuntimeServices->ResetSystem, 4, EfiResetCold, EFI_SUCCESS, 0, NULL);

    return Status; 
}
