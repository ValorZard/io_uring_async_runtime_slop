with Ada.Real_Time;
with Iour;

package Http_Client_App with SPARK_Mode => On is

    procedure Configure
       (Host : String; Port : Natural; Connections : Natural; Rounds : Natural);
    procedure Start (Started : out Boolean);
    procedure Result
       (Started : out Natural; Succeeded : out Natural;
         Failed : out Natural; Requests : out Natural);
      procedure Session_Window
         (From : out Ada.Real_Time.Time; To : out Ada.Real_Time.Time);

end Http_Client_App;