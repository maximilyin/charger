defmodule Charger.Chargers.FixtureSource do
  @moduledoc false

  @key {__MODULE__, :fetches}

  def fetch do
    :persistent_term.put(@key, fetch_count() + 1)
    {:ok, csv()}
  end

  def fetch_count, do: :persistent_term.get(@key, 0)

  def csv do
    """
    COMUNIDAD AUTONOMA;PROVINCIA;MUNICIPIO;LATITUD;LONGITUD;NOMBRE INSTALACION;DIRECCIÓN;CODIGO POSTAL;LOCALIZACION;TIPO HORARIO APERTURA;HORARIO APERTURA;NOMBRE OPERADOR;COD.OPERADOR;TIPOS DE SERVICIOS;COD.INSTALACION;ID. PUNTO DE RECARGA;ACCESIBILIDAD;METODOS DE PAGOS;COD. PUNTO DE RECARGA;ID. CONECTOR;TIPO CONECTOR;TIPO DE CARGA;FORMATO;POTENCIA MAXIMA;VOLTAJE;INTENSIDAD;FECHA DE ULTIMA MODIFICACION
    Madrid, Comunidad de;Madrid;Madrid;="40.432861";="-3.724194";Repsol Alcala;CALLE ALCALA, 1;="28001";="EN LA CALLE"; 24/7;;REPSOL;ES*REP;;SITE-A;ES*REP*1;;RFID;PR1;1;IEC_62196_T2;AC_1_PHASE;Cable;7,40 kW;230 V;32,00 A;01/10/2026 10:00:00
    Madrid, Comunidad de;Madrid;Madrid;="40.432861";="-3.724194";Repsol Alcala;CALLE ALCALA, 1;="28001";="EN LA CALLE"; 24/7;;REPSOL;ES*REP;;SITE-A;ES*REP*1;;RFID;PR1;2;IEC_62196_T2_COMBO;DC;Cable;50,00 kW;400 V;125,00 A;01/10/2026 10:00:00
    "Andalucía";"Cádiz";"Puerto Real";="36.520486";="-6.224294";"Puerto";"C/ Francia.
    Polígono";="11519";;;;;;;SITE-B;;;;;;;;;;
    """
  end
end
