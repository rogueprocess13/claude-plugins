package com.example.billing;

import jakarta.persistence.*;

@Entity
@Table(name = "invoice")
public class Invoice {

    @Id
    private Long reminderCount;
}
